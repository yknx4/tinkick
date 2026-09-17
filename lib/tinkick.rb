# frozen_string_literal: true

require_relative "tinkick/version"
require_relative "tinkick/errors"
require_relative "tinkick/filter"
require_relative "tinkick/query_text"
require_relative "tinkick/hash_wrapper"
require_relative "tinkick/query"
require_relative "tinkick/highlighter"
require_relative "tinkick/results"
require_relative "tinkick/relation"
require_relative "tinkick/model"
require "active_support/lazy_load_hooks"

module Tinkick
  class << self
    attr_accessor :search_method_name, :model_options

    def search(term = "*", model:, fields: nil, misspellings: true, where: {}, order: nil,
      limit: nil, offset: nil, page: nil, per_page: nil, padding: nil, match: nil,
      operator: "and", load: true, total_entries: nil, countless: false, keyset: false,
      after: nil, aggs: nil, smart_aggs: true, includes: nil, model_includes: nil, scope_results: nil, exclude: nil, select: nil, highlight: nil, boost_by: nil, boost_where: nil, boost: nil)
      model.tinkick_search(term, fields: fields, misspellings: misspellings, where: where, order: order,
        limit: limit, offset: offset, page: page, per_page: per_page, padding: padding, match: match,
        operator: operator, load: load, total_entries: total_entries, countless: countless, keyset: keyset,
        after: after, aggs: aggs, smart_aggs: smart_aggs, includes: includes, model_includes: model_includes, scope_results: scope_results, exclude: exclude, select: select, highlight: highlight, boost_by: boost_by, boost_where: boost_where, boost: boost)
    end
  end

  self.search_method_name = :search
  self.model_options = {}
end

ActiveSupport.on_load(:active_record) do
  extend Tinkick::Model
end
