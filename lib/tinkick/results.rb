# frozen_string_literal: true

require "forwardable"
require "active_support/core_ext/object/deep_dup"
require_relative "hash_wrapper"
require_relative "query"
require_relative "source_filter"
require_relative "highlights"

module Tinkick
  class Results
    include Enumerable
    extend Forwardable

    def_delegators :results, :each, :any?, :empty?, :size, :length, :slice, :[], :to_ary
    attr_reader :current_page, :padding

    def initialize(query, page: 1, padding: 0, total_entries: nil, load: true, includes: nil, model_includes: nil, scope_results: nil, select: nil, highlight: nil)
      if query.keyset? && (page != 1 || !padding.zero?)
        raise InvalidQueryError, "keyset pagination does not accept page or padding; use after: with next_cursor"
      end
      @query = query
      @current_page = page
      @padding = padding
      @total_entries = total_entries
      @load = load
      @includes = includes
      @model_includes = model_includes
      @scope_results = scope_results
      @select = select
      @highlighter = Highlights.new(query, highlight) if highlight
      @missing_records = []
      @hit_pairs = []
      unless load
        @query.model.logger&.warn("Tinkick: load: false is supported for Searchkick compatibility. Migrate to model results when possible; both modes query PostgreSQL through Active Record.")
      end
    end

    def aggs
      @query.aggs
    end

    def aggregations
      values = aggs
      return unless values

      values.to_h do |name, result|
        value = if result.key?("doc_count")
          nested = result.except("doc_count") #: aggregation_result
          { "doc_count" => result.fetch("doc_count"), name => nested }
        else
          result
        end
        [name, value]
      end
    end

    def model_name
      @query.model.model_name
    end

    def entry_name(options = {})
      name = model_name.human #: String
      return name.downcase if options.empty?

      default = options[:count] == 1 ? name : name.pluralize
      model_name.human(options.reverse_merge(default: default))
    end

    def missing_records
      record_pairs
      @missing_records
    end

    def misspellings?
      @query.misspellings?
    end

    def took
      load_page
      @query.took || 0
    end

    def error
      load_page
      nil
    end

    def hits
      @hits ||= begin
        rows = if @load
          @scope_results ? @query.rows : @query.records.map(&:attributes)
        else
          source_rows
        end #: Array[Hash[String, result_value]]
        include_source = @select != [] && (!@load || @select)
        filter = source_filter if include_source && @select && @select != true
        highlighted = @highlighter&.call(@highlight_rows || rows)
        rows.each_with_index.map do |row, index|
          score = row.fetch("_tinkick_score") #: Float | BigDecimal
          hit = { "_id" => row.fetch(@query.model.primary_key.to_s).to_s,
                  "_index" => @query.model.table_name, "_score" => score.to_f } #: search_hit
          if include_source
            source = row.except("_tinkick_score")
            selected = filter ? filter.call(source) : source
            hit["_source"] = selected.deep_dup
          end
          values = highlighted&.fetch(index)
          hit["highlight"] = values if values && !values.empty?
          hit
        end
      end
    end

    def with_hit
      return enum_for(:with_hit) unless block_given?

      record_pairs
      @hit_pairs.each { |record, hit| yield record, hit }
    end

    def response
      @response ||= begin
        page = { "hits" => hits } #: response_hits
        unless @query.countless? && @total_entries.nil?
          page["total"] = { "value" => total_count, "relation" => "eq" }
        end
        value = { "took" => took, "hits" => page } #: search_response
        values = aggregations
        value["aggregations"] = values if values
        value
      end
    end

    def highlights(multiple: false)
      hits.map { |hit| hit_highlights(hit, multiple: multiple) }
    end

    def with_highlights(multiple: false)
      return enum_for(:with_highlights, multiple: multiple) unless block_given?

      with_hit.each { |record, hit| yield record, hit_highlights(hit, multiple: multiple) }
    end

    def total_count
      @query.misspellings?
      @total_entries || @query.total_count
    end
    alias_method :total_entries, :total_count

    def per_page
      @query.limit
    end
    alias_method :limit_value, :per_page

    def total_pages
      (total_count / per_page.to_f).ceil
    end
    alias_method :num_pages, :total_pages

    def offset_value
      (current_page - 1) * per_page + padding
    end
    alias_method :offset, :offset_value

    def previous_page
      current_page > 1 ? current_page - 1 : nil
    end
    alias_method :prev_page, :previous_page

    def next_page
      raise InvalidQueryError, "keyset pagination uses next_cursor instead of next_page" if @query.keyset?

      return has_next_page? ? current_page + 1 : nil if @query.countless?

      current_page < total_pages ? current_page + 1 : nil
    end

    def has_next_page?
      return current_page < total_pages unless @query.countless?

      results
      @query.has_next_page?
    end

    def next_cursor
      return unless @query.keyset?

      results
      @query.next_cursor
    end

    def first_page?
      return @query.after.nil? if @query.keyset?

      previous_page.nil?
    end

    def last_page?
      return !has_next_page? if @query.countless?

      next_page.nil?
    end

    def out_of_range?
      if @query.countless?
        return @query.rows.empty? if @load && @scope_results

        return empty?
      end

      current_page > total_pages
    end

    def with_score
      return enum_for(:with_score) unless block_given?

      record_pairs.each { |record, score| yield record, score }
    end

    def pluck(*keys)
      if keys.length > 1
        results.map { |record| keys.map { |key| record[key.to_s] } }
      else
        key = keys.first.to_s
        results.map { |record| record[key] }
      end
    end

    private

    def hit_highlights(hit, multiple: false)
      values = hit["highlight"] || {}
      values.to_h { |name, fragments| [name.to_sym, multiple ? fragments : fragments.fetch(0)] }
    end

    def load_page
      if @load
        @scope_results ? @query.rows : @query.records
      else
        source_rows
      end
    end

    def results
      @results ||= record_pairs.map(&:first)
    end

    def preload_records(records)
      associations = [@includes, @model_includes&.[](@query.model)].compact.flatten #: Array[association_spec]
      unless associations.empty?
        ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
      end
      records
    end

    def scoped_record_pairs(scope)
      rows = @query.rows
      return [] if rows.empty?

      primary_key = @query.model.primary_key
      unless primary_key.is_a?(String)
        raise InvalidQueryError, "scope_results requires a single model primary key"
      end
      @query.model.logger&.warn("Tinkick: scope_results runs a second, page-bounded Active Record query after search pagination. It can remove page results without changing total_count; prefer where: for filters that should affect search totals or pagination.")
      identifiers = rows.map { |row| row.fetch(primary_key) }
      loaded = scope.call(@query.model.all).where(primary_key => identifiers).to_a #: Array[ActiveRecord::Base]
      indexed = loaded.to_h { |record| [record[primary_key], record] }
      missing = [] #: Array[missing_record]
      # @type var pairs: Array[[ActiveRecord::Base, Float]]
      pairs = rows.filter_map do |row|
        record = indexed[row.fetch(primary_key)]
        unless record
          missing << { id: row.fetch(primary_key).to_s, model: @query.model }
          next
        end

        score = row.fetch("_tinkick_score") #: Float | BigDecimal
        [record, score.to_f]
      end
      preload_records(pairs.map(&:first))
      @missing_records = missing
      pairs
    end

    def source_rows
      @source_rows ||= read_source_rows
    end

    def read_source_rows
      selection = @select
      return @query.rows if selection.nil? || selection == true || selection == false
      filter = source_filter
      definitions = @query.model.columns_hash
      if filter.nested?(definitions)
        @query.model.logger&.warn("Tinkick: nested source selection reads each selected JSON column for the bounded result page, then prunes properties in Ruby. Large JSON values can increase transfer and memory costs; use dedicated stored or generated columns for frequent narrow projections.")
      end
      rows = @query.source_rows(filter.columns(definitions) | (@highlighter&.columns || []))
      @highlight_rows = rows if @highlighter
      rows.map do |row|
        filter.call(row).merge(row.slice(@query.model.primary_key.to_s, "_tinkick_score"))
      end
    end

    def source_filter
      @source_filter ||= begin
        selection = @select
        unless selection.is_a?(String) || selection.is_a?(Symbol) || selection.is_a?(Array) || selection.is_a?(Hash)
          raise InvalidQueryError, "select accepts source field names or an includes/excludes map"
        end
        SourceFilter.new(selection)
      end
    end

    def record_pairs
      cached = @record_pairs
      return cached if cached

      indexed = hits.to_h { |hit| [hit.fetch("_id"), hit] }
      # @type var pairs: Array[[result_record, Float]]
      pairs = if @load
        scope = @scope_results
        if scope
          scoped_record_pairs(scope)
        else
          preload_records(@query.records).map { |record| [record, record[:_tinkick_score].to_f] }
        end
      else
        source_rows.map do |row|
          # Query projects a numeric score alongside the arbitrary model fields.
          score = row.fetch("_tinkick_score") #: Float | BigDecimal
          [HashWrapper.new(row.except("_tinkick_score")), score.to_f]
        end
      end
      @hit_pairs = pairs.map do |record, _score|
        hit = indexed.fetch(record[@query.model.primary_key.to_s].to_s)
        highlighter = @highlighter
        if highlighter
          values = hit_highlights(hit)
          if record.is_a?(HashWrapper)
            highlighter.fields.each_key do |name|
              record.to_h["highlighted_#{name}"] = values[name.to_sym] || record[name]
            end
          elsif !record.respond_to?(:search_highlights)
            record.define_singleton_method(:search_highlights) { values }
          end
        end
        [record, hit]
      end
      @record_pairs = pairs
    end
  end
end
