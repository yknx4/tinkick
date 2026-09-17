# frozen_string_literal: true

require "bundler/setup"

if ENV["COVERAGE"] == "1"
  require "simplecov"
  SimpleCov.start do
    root File.expand_path("..", __dir__)
    no_default_skips
    cover "lib/**/*.rb"
    merging false
    coverage :line, minimum: 90
  end
end

require "minitest/autorun"
require "open3"
require "rbconfig"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "tinkick"
