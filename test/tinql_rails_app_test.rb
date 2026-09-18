# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"
require_relative "integration_helper"
require "rails/test_help"

class TinqlRailsAppTest < ActionDispatch::IntegrationTest
  self.fixture_paths = [File.expand_path("dummy/test/fixtures", __dir__)]
  self.use_transactional_tests = true
  set_fixture_class(tinkick_test_documents: SearchDocument)
  fixtures :tinkick_test_documents

  def test_native_proximity_filters_a_real_http_response
    get "/documents", params: { left: "Gondolin", right: "sentries", distance: 0 }
    assert_response :success
    expected = [:phrase_ordered, :phrase_reversed].map { |key| tinkick_test_documents(key).id }.sort
    assert_equal expected, response.parsed_body.fetch("documents").map { |row| row.fetch("id") }.sort
    refute response.parsed_body.fetch("has_next_page")

    get "/documents", params: { left: "Gondolin", right: "sentries", distance: 1 }
    assert_response :success
    assert_equal 3, response.parsed_body.fetch("documents").length
  end

  def test_sql_filters_and_literal_input_remain_effective
    get "/documents", params: { left: "Gondolin", right: "sentries", category: "food" }
    assert_response :success
    assert_empty response.parsed_body.fetch("documents")

    get "/documents", params: { left: 'Gondolin" OR *', right: "sentries" }
    assert_response :success
    assert_empty response.parsed_body.fetch("documents")
  end

  def test_invalid_distance_returns_a_bad_request
    get "/documents", params: { left: "Gondolin", right: "sentries", distance: -1 }
    assert_response :bad_request
  end
end
