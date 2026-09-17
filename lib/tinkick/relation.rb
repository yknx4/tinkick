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
      :previous_page, :prev_page, :next_page, :first_page?, :last_page?, :out_of_range?, :with_score

    def initialize(model, term = "*", fields:, misspellings:, where: {}, order: nil, limit: nil, offset: nil, page: nil, per_page: nil, padding: nil, match: :word, operator: "and", load: true, total_entries: nil)
      @model = model
      @term = term
      @options = {
        fields: fields, misspellings: misspellings, where: where, order: order,
        limit: limit, offset: offset, page: page, per_page: per_page, padding: padding,
        match: match, operator: operator, load: load, total_entries: total_entries,
      }
      query
    end

    def loaded?
      !@results.nil?
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
      @query ||= Query.new(@model, @term,
        fields: @options[:fields], where: @options[:where], order: @options[:order],
        limit: page_size, offset: (@options[:offset] || (page_number - 1) * page_size + page_padding).to_i,
        match: @options[:match], operator: @options[:operator], misspellings: @options[:misspellings])
    end

    def execute
      load_value = @options[:load]
      @results ||= Results.new(query, page: page_number, padding: page_padding,
        total_entries: @options[:total_entries], load: load_value.nil? ? true : load_value)
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
