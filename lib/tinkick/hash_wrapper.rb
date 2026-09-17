# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/object/json"

module Tinkick
  class HashWrapper
    def initialize(attributes)
      @attributes = attributes
    end

    def [](name)
      @attributes[name.to_s]
    end

    def to_h
      @attributes
    end

    def as_json(options = nil)
      @attributes.as_json(options)
    end

    def to_json(options = nil)
      @attributes.to_json(options)
    end

    def inspect
      names = @attributes.keys.reject { |name| name.start_with?("_") }
      names.unshift("id") if names.delete("id")
      fields = names.map { |name| "#{name}: #{@attributes[name].inspect}" }
      "#<#{self.class.name} #{fields.join(", ")}>"
    end

    private

    def method_missing(name, *args, &block)
      return self[name] if @attributes.key?(name.to_s)

      super
    end

    def respond_to_missing?(name, include_private = false)
      @attributes.key?(name.to_s) || super
    end
  end
end
