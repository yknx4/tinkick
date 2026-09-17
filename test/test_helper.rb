# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "open3"
require "rbconfig"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "tinkick"
