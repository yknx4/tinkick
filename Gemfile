# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Keep the seeded Tolkien fixtures stable across dependency resolution.
gem "faker", "3.8.0"
gem "flay", "~> 2.14", require: false
gem "flog", "~> 4.9", require: false
gem "json", ENV.fetch("JSON_VERSION", "< 3")
gem "minitest", "~> 5.25"
gem "rails", ENV.fetch("RAILS_VERSION", ">= 8.0")
gem "rake", "~> 13.0"
gem "rbs", "~> 4.2"
gem "rubocop-shopify", "~> 3.1"
gem "searchkick", "6.1.2", require: false
gem "simplecov", "~> 1.2", require: false
gem "steep", "~> 2.1"
