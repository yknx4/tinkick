# frozen_string_literal: true

require "forwardable"
require_relative "hash_wrapper"
require_relative "query"

module Tinkick
  class Results
    include Enumerable
    extend Forwardable

    def_delegators :results, :each, :any?, :empty?, :size, :length, :slice, :[], :to_ary
    attr_reader :current_page, :padding

    def initialize(query, page: 1, padding: 0, total_entries: nil, load: true)
      if query.keyset? && (page != 1 || !padding.zero?)
        raise InvalidQueryError, "keyset pagination does not accept page or padding; use after: with next_cursor"
      end
      @query = query
      @current_page = page
      @padding = padding
      @total_entries = total_entries
      @load = load
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

    def total_count
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
      return empty? if @query.countless?

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

    def results
      @results ||= record_pairs.map(&:first)
    end

    def record_pairs
      @record_pairs ||= if @load
        @query.records.map { |record| [record, record[:_tinkick_score].to_f] }
      else
        @query.rows.map do |row|
          # Query projects a numeric score alongside the arbitrary model fields.
          score = row.fetch("_tinkick_score") #: Float | BigDecimal
          [HashWrapper.new(row.except("_tinkick_score")), score.to_f]
        end
      end
    end
  end
end
