# frozen_string_literal: true

require_relative "../integration_helper"

class RawValuesTest < TinkickIntegrationTest
  def test_raw_results_deserialize_postgresql_arrays_and_json_without_model_instantiation
    product = tinkick_test_products(:red_apple)
    product.update!(tags: ["red", "fresh"], ratings: [1, 5], metadata: { "origin" => { "country" => "Canada" } })
    query = Tinkick::Query.new(SearchProduct, "apple", fields: [:name])
    results = Tinkick::Results.new(query, load: false)
    instantiated = []
    callback = ->(_name, _start, _finish, _id, payload) { instantiated << payload[:class_name] }
    record = nil
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") { record = results.first }

    assert_equal ["red", "fresh"], record.tags
    assert_equal [1, 5], record.ratings
    assert_equal({ "origin" => { "country" => "Canada" } }, record.metadata)
    assert_equal product.id, record.id
    assert_empty instantiated
    assert_operator results.with_score.first.last, :>, 0
  end

  def test_raw_pluck_preserves_array_json_and_null_values
    tinkick_test_products(:red_apple).update!(tags: ["red"], metadata: { "available" => true })
    query = Tinkick::Query.new(SearchProduct, "*", fields: [:name], order: :id)

    assert_equal [
      { "tags" => ["red"], "metadata" => { "available" => true } },
      { "tags" => nil, "metadata" => nil },
    ], query.pluck_rows([:tags, :metadata])
  end
end
