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

ActiveSupport.on_load(:active_record) do
  extend Tinkick::Model
end
