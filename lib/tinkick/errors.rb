# frozen_string_literal: true

module Tinkick
  class Error < StandardError; end
  class InvalidQueryError < Error; end
  class MissingFieldError < Error; end
end
