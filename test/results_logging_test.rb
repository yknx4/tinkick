# frozen_string_literal: true

require_relative "test_helper"
require "logger"
require "stringio"

class ResultsLoggingTest < Minitest::Test
  class Product < ActiveRecord::Base
    self.abstract_class = true
  end

  def setup
    @original_logger = Product.logger
    @output = StringIO.new
    Product.logger = Logger.new(@output)
    @query = Tinkick::Query.new(Product, "*", fields: [:name])
  end

  def teardown
    Product.logger = @original_logger
  end

  def test_unloaded_results_warn_about_migration_without_connecting
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Tinkick::Results.new(@query, load: false)
    end

    assert_match "WARN", @output.string
    assert_match "load: false", @output.string
    assert_match "Migrate to model results", @output.string
    assert_match "both modes query PostgreSQL through Active Record", @output.string
    assert_empty statements
  end

  def test_normal_model_results_do_not_warn
    Tinkick::Results.new(@query)

    assert_empty @output.string
  end

  def test_a_missing_model_logger_is_supported
    Product.logger = nil

    assert_instance_of Tinkick::Results, Tinkick::Results.new(@query, load: false)
  end
end
