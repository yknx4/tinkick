# frozen_string_literal: true

require "forwardable"
require_relative "results"

module Tinkick
  class Relation
    include Enumerable
    extend Forwardable

    class DefaultValue; end
    NO_DEFAULT_VALUE = DefaultValue.new.freeze

    attr_reader :model
    alias_method :klass, :model
    def_delegators :execute, :each, :any?, :empty?, :size, :length, :slice, :[], :to_ary,
      :total_count, :current_page, :limit_value, :total_pages, :num_pages, :offset_value,
      :previous_page, :prev_page, :next_page, :first_page?, :last_page?, :out_of_range?, :with_score,
      :has_next_page?, :next_cursor, :aggregations, :model_name, :entry_name, :missing_records, :misspellings?, :took, :error, :hits, :with_hit, :response, :highlights, :with_highlights

    def initialize(model, term = "*", fields:, misspellings:, where: {}, order: nil, limit: nil, offset: nil, page: nil, per_page: nil, padding: nil, match: :word, operator: "and", load: true, total_entries: nil, countless: false, keyset: false, after: nil, aggs: nil, smart_aggs: true, includes: nil, model_includes: nil, scope_results: nil, select: nil, exclude: nil, highlight: nil, boost_by: nil, boost_where: nil, boost: nil, boost_by_recency: nil)
      @model = model
      @term = term
      @options = {
        fields: fields, misspellings: misspellings, where: where, order: order,
        limit: limit, offset: offset, page: page, per_page: per_page, padding: padding,
        match: match, operator: operator, load: load, total_entries: total_entries,
        countless: countless, keyset: keyset, after: after, aggs: aggs, smart_aggs: smart_aggs, includes: includes, model_includes: model_includes, scope_results: scope_results,
        select: select, exclude: exclude, highlight: highlight, boost_by: boost_by, boost_where: boost_where, boost: boost, boost_by_recency: boost_by_recency,
      }
      query
    end

    def loaded?
      !@results.nil?
    end

    def only(*keys)
      options = @options.slice(*keys) #: relation_option_subset
      @model.tinkick_search(@term, **options)
    end

    def except(*keys)
      options = @options.except(*keys) #: relation_option_subset
      @model.tinkick_search(@term, **options)
    end

    def countless(value = true)
      clone.countless!(value)
    end

    def countless!(value = true)
      check_loaded
      @options[:countless] = value
      self
    end

    def keyset(after: nil)
      clone.keyset!(after: after)
    end

    def keyset!(after: nil)
      check_loaded
      @options[:keyset] = true
      @options[:after] = after
      self
    end

    # @type method load: (?(bool? | DefaultValue) value) -> Relation
    def load(value = NO_DEFAULT_VALUE)
      if value.is_a?(DefaultValue)
        execute.to_a
        self
      else
        clone.load!(value)
      end
    end

    def load!(value)
      check_loaded
      @options[:load] = value
      self
    end

    def highlight(value = true)
      clone.highlight!(value)
    end

    def highlight!(value = true)
      check_loaded
      @options[:highlight] = value
      self
    end

    def boost(value)
      clone.boost!(value)
    end

    def boost!(value)
      check_loaded
      @options[:boost] = value
      self
    end

    def boost_by(value)
      clone.boost_by!(value)
    end

    def boost_by_recency(value)
      clone.boost_by_recency!(value)
    end

    def boost_by_recency!(value)
      check_loaded
      @options[:boost_by_recency] = (@options[:boost_by_recency] || {}).merge(value)
      self
    end

    def boost_where(value)
      clone.boost_where!(value)
    end

    def boost_where!(value)
      check_loaded
      @options[:boost_where] = (@options[:boost_where] || {}).merge(value)
      self
    end

    def boost_by!(value)
      check_loaded
      additions = if value.is_a?(Hash)
        value
      elsif value.is_a?(Array)
        value.to_h { |field| [field, { factor: 1 }] }
      else
        { value => { factor: 1 } }
      end #: Hash[String | Symbol, numeric_boost_options]
      previous = @options[:boost_by]
      existing = if previous.is_a?(Array)
        previous.to_h { |field| [field, { factor: 1 }] }
      else
        previous || {}
      end #: Hash[String | Symbol, numeric_boost_options]
      @options[:boost_by] = existing.merge(additions)
      self
    end

    def includes(*values)
      clone.includes!(*values)
    end

    def includes!(*values)
      check_loaded
      previous = @options[:includes]
      @options[:includes] = previous ? [previous, *values] : values
      self
    end

    def model_includes(values)
      clone.model_includes!(values)
    end

    def model_includes!(values)
      check_loaded
      @options[:model_includes] = (@options[:model_includes] || {}).merge(values)
      self
    end

    def scope_results(value)
      clone.scope_results!(value)
    end

    def scope_results!(value)
      check_loaded
      @options[:scope_results] = value
      self
    end

    # @type method select: (*source_fields values) ?{ (result_record) -> boolish } -> (Relation | Array[result_record])
    def select(*values, &block)
      if block
        raise ArgumentError, "wrong number of arguments (given #{values.length}, expected 0)" unless values.empty?

        execute.select(&block)
      else
        clone.select!(*values)
      end
    end

    def select!(*values)
      check_loaded
      previous = @options[:select]
      if previous == true || previous.is_a?(Hash)
        raise InvalidQueryError, "select cannot append fields to true or an includes/excludes map; use reselect to replace it"
      end
      existing = previous ? Array(previous) : [] #: Array[String | Symbol]
      @options[:select] = existing + values.flatten
      self
    end

    def reselect(*values)
      clone.reselect!(*values)
    end

    def reselect!(*values)
      check_loaded
      @options[:select] = values.flatten
      self
    end

    def exclude(*values)
      clone.exclude!(*values)
    end

    def exclude!(*values)
      check_loaded
      previous = @options[:exclude]
      existing = previous ? Array(previous) : [] #: Array[exclusion_scalar]
      @options[:exclude] = existing + values.flatten.compact
      self
    end

    def aggs(*values, **options)
      return execute.aggs if values.empty? && options.empty?

      clone.aggs!(*values, **options)
    end

    def aggs!(*values, **options)
      check_loaded
      previous = @options[:aggs]
      specifications = if previous.is_a?(Array)
        previous.to_h do |field|
          empty_options = {} #: aggregation_options
          [field, empty_options]
        end
      else
        (previous || {})
      end
      additions = {} #: Hash[String | Symbol, aggregation_options]
      values.flatten.each do |value|
        value.is_a?(Hash) ? additions.merge!(value) : additions[value] = {}
      end
      @options[:aggs] = specifications.merge(additions).merge(options)
      self
    end

    def smart_aggs(value)
      clone.smart_aggs!(value)
    end

    def smart_aggs!(value)
      check_loaded
      @options[:smart_aggs] = value
      self
    end

    def fields(*values)
      clone.fields!(*values)
    end

    def fields!(*values)
      check_loaded
      @options[:fields] = @options[:fields] + values.flat_map { |value| value.is_a?(Array) ? value : [value] }
      self
    end

    # @type method where: (?(filter_conditions? | DefaultValue) value) -> (Where | Relation)
    def where(value = NO_DEFAULT_VALUE)
      return Where.new(self) if value.is_a?(DefaultValue)

      clone.where!(value.nil? ? {} : value)
    end

    def where!(value)
      check_loaded
      value = value.to_h
      previous = @options[:where]
      @options[:where] = if previous.keys.intersect?(value.keys)
        conjunction = previous[:_and]
        if conjunction.is_a?(Array)
          previous.merge(_and: conjunction + [value])
        else
          { _and: [previous, value] }
        end
      else
        previous.merge(value)
      end
      self
    end

    def rewhere(value)
      clone.rewhere!(value)
    end

    def rewhere!(value)
      check_loaded
      @options[:where] = value.to_h
      self
    end

    def order(*values)
      clone.order!(*values)
    end

    def order!(*values)
      check_loaded
      previous = @options[:order]
      @options[:order] = previous ? [previous, *values] : values
      self
    end

    def reorder(*values)
      clone.reorder!(*values)
    end

    def reorder!(*values)
      check_loaded
      @options[:order] = values
      self
    end

    def limit(value)
      clone.limit!(value)
    end

    def limit!(value)
      check_loaded
      @options[:limit] = value
      self
    end

    # @type method offset: (?(relation_number | DefaultValue) value) -> (Integer | Relation)
    def offset(value = NO_DEFAULT_VALUE)
      return execute.offset if value.is_a?(DefaultValue)

      clone.offset!(value)
    end

    def offset!(value)
      check_loaded
      @options[:offset] = value
      self
    end

    def page(value)
      clone.page!(value)
    end

    def page!(value)
      check_loaded
      @options[:page] = value
      self
    end

    # @type method per_page: (?(relation_number | DefaultValue) value) -> (Integer | Relation)
    def per_page(value = NO_DEFAULT_VALUE)
      return execute.per_page if value.is_a?(DefaultValue)

      clone.per_page!(value)
    end

    def per(value)
      per_page(value)
    end

    def per_page!(value)
      check_loaded
      @options[:per_page] = value
      self
    end

    # @type method padding: (?(relation_number | DefaultValue) value) -> (Integer | Relation)
    def padding(value = NO_DEFAULT_VALUE)
      return execute.padding if value.is_a?(DefaultValue)

      clone.padding!(value)
    end

    def padding!(value)
      check_loaded
      @options[:padding] = value
      self
    end

    def match(value)
      clone.match!(value)
    end

    def match!(value)
      check_loaded
      @options[:match] = value
      self
    end

    def operator(value)
      clone.operator!(value)
    end

    def operator!(value)
      check_loaded
      @options[:operator] = value
      self
    end

    def misspellings(value)
      clone.misspellings!(value)
    end

    def misspellings!(value)
      check_loaded
      @options[:misspellings] = value
      self
    end

    # @type method total_entries: (?(Integer? | DefaultValue) value) -> (Integer | Relation)
    def total_entries(value = NO_DEFAULT_VALUE)
      return execute.total_entries if value.is_a?(DefaultValue)

      clone.total_entries!(value)
    end

    def total_entries!(value)
      check_loaded
      @options[:total_entries] = value
      self
    end

    # @type method first: (?(Integer | DefaultValue) value) -> (result_record? | Array[result_record])
    def first(value = NO_DEFAULT_VALUE)
      return [] if value == 0

      single = value.is_a?(DefaultValue)
      requested = value.is_a?(DefaultValue) ? 1 : value
      records = if loaded?
        execute.to_a
      else
        requested = page_size if page_size < requested
        limit(requested).load.to_a
      end
      single ? records.first : records.first(requested)
    end

    def pluck(*keys)
      return execute.pluck(*keys) if loaded? || @options[:load] != false

      @model.logger&.warn("Tinkick: load: false is supported for Searchkick compatibility. Migrate to model results when possible; both modes query PostgreSQL through Active Record.")
      rows = query.pluck_rows(keys)
      if keys.length > 1
        rows.map { |row| keys.map { |key| row[key.to_s] } }
      else
        key = keys.first.to_s
        rows.map { |row| row[key] }
      end
    end

    private

    def initialize_copy(other)
      super
      @options = @options.dup
      @query = nil
      @results = nil
    end

    def check_loaded
      raise Error, "Relation loaded" if loaded?

      @query = nil
    end

    def page_number
      [@options[:page].to_i, 1].max
    end

    def page_size
      (@options[:limit] || @options[:per_page] || 10_000).to_i
    end

    def page_padding
      [@options[:padding].to_i, 0].max
    end

    def query
      if @options[:keyset] && (!@options[:offset].nil? || @options[:page].to_i > 1 || !@options[:padding].to_i.zero?)
        raise InvalidQueryError, "keyset pagination does not accept offset, page > 1, or padding; use after: with next_cursor"
      end
      @query ||= Query.new(@model, @term,
        fields: @options[:fields], where: @options[:where], order: @options[:order],
        limit: page_size, offset: @options[:keyset] ? nil : (@options[:offset] || (page_number - 1) * page_size + page_padding).to_i,
        match: @options[:match], operator: @options[:operator], misspellings: @options[:misspellings],
        countless: @options[:countless], keyset: @options[:keyset], after: @options[:after], aggs: @options[:aggs], smart_aggs: @options[:smart_aggs], exclude: @options[:exclude], boost_by: @options[:boost_by], boost_where: @options[:boost_where], boost: @options[:boost], boost_by_recency: @options[:boost_by_recency])
    end

    def execute
      load_value = @options[:load]
      @results ||= Results.new(query, page: page_number, padding: page_padding,
        total_entries: @options[:total_entries], load: load_value.nil? ? true : load_value, includes: @options[:includes], model_includes: @options[:model_includes], scope_results: @options[:scope_results], select: @options[:select], highlight: @options[:highlight])
    end
  end

  class Where
    def initialize(relation)
      @relation = relation
    end

    def not(conditions)
      @relation.where(_not: conditions)
    end
  end
end
