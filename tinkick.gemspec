# frozen_string_literal: true

require_relative "lib/tinkick/version"

Gem::Specification.new do |spec|
  spec.name = "tinkick"
  spec.version = Tinkick::VERSION
  spec.authors = ["yknx4"]
  spec.summary = "Searchkick-compatible search for Rails using PlanetScale TIN."
  spec.description = "A Ruby 4 and Rails 8+ gem targeting the Searchkick API with PostgreSQL TIN as its search backend. Currently a development scaffold."
  spec.homepage = "https://github.com/yknx4/tinkick"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "lib/**/*.tt", "sig/**/*.rbs", "docs/**/*.md", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency("activerecord", ">= 8.0")
  spec.add_dependency("pg", ">= 1.6")
end
