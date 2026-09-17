# frozen_string_literal: true

require_relative "test_helper"
require "tinkick/hash_wrapper"

class HashWrapperTest < Minitest::Test
  def setup
    @result = Tinkick::HashWrapper.new("id" => "7", "name" => "Red Apple", "_score" => 1.5)
  end

  def test_field_access_matches_searchkick_results
    assert_equal("Red Apple", @result.name)
    assert_equal("Red Apple", @result[:name])
    assert_equal("Red Apple", @result["name"])
    assert_nil(@result[:missing])
    assert_respond_to(@result, :name)
    refute_respond_to(@result, :missing)
    assert_raises(NoMethodError) { @result.missing }
  end

  def test_serialization_preserves_hash_projection_semantics
    assert_equal("7", @result.to_h.fetch("id"))
    assert_equal({ "name" => "Red Apple" }, @result.as_json(only: ["name"]))
    assert_empty(@result.as_json(only: [:name]))
    assert_equal({ "id" => "7", "name" => "Red Apple", "_score" => 1.5 }, JSON.parse(@result.to_json))
  end

  def test_inspect_starts_with_id_and_hides_internal_metadata
    assert_match(/ id: "7", name: "Red Apple">\z/, @result.inspect)
    refute_includes(@result.inspect, "_score")
  end
end
