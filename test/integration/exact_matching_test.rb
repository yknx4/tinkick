# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/model"

class ExactMatchingTest < TinkickIntegrationTest
  class RemoveDescriptionIndex < ActiveRecord::Migration[8.0]
    def change
      remove_index :tinkick_test_products, :description, using: :tin
    end
  end

  def test_exact_matches_the_entire_value_with_case_and_accents_preserved
    product = tinkick_test_products(:red_apple)
    product.update!(name: "Café of Rivendell")

    assert_equal([product.id], search("Café of Rivendell").map(&:id))
    ["café of Rivendell", "Cafe of Rivendell", "Rivendell", "Café of Rivendell "].each do |term|
      assert_empty(search(term))
    end
  end

  def test_exact_ignores_fuzziness_and_preserves_literal_query_syntax
    product = tinkick_test_products(:red_apple)
    product.update!(name: "Moria' OR 1=1 -- %_\\")

    assert_equal([product.id], search(product.name, misspellings: true).map(&:id))
    assert_empty(search("Moria' OR 1=1 -- %_", misspellings: true))
    assert_empty(search("Moria' OR *"))
  end

  def test_exact_applies_filters_counts_and_bounded_pagination
    tinkick_test_products(:red_apple).update!(name: "Moria")
    tinkick_test_products(:green_pear).update!(name: "Moria")
    expected = SearchProduct.order(:id).ids
    results = search("Moria", order: :id, offset: 1, limit: 1)

    assert_equal([expected.last], results.map(&:id))
    assert_equal(2, results.total_count)
    assert_equal([expected.first], search("Moria", where: { id: expected.first }).map(&:id))
    assert_equal([1.0], results.with_score.map { |_record, score| score })
    assert_equal(expected, search("*", order: :id).map(&:id))
  end

  def test_exact_can_search_an_empty_string_but_not_null
    tinkick_test_products(:red_apple).update!(description: "")
    tinkick_test_products(:green_pear).update!(description: nil)

    assert_equal([tinkick_test_products(:red_apple).id], search("", fields: [:description]).map(&:id))
  end

  def test_exact_uses_sql_without_a_tin_index_or_tokenization
    migration = RemoveDescriptionIndex.new
    migration.migrate(:up)
    begin
      model = Class.new(SearchProduct) do
        extend Tinkick::Model
        tinkick searchable: [:description], match: :exact
      end
      statements = []
      callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        assert_equal(["Red Apple"], model.search(tinkick_test_products(:red_apple).description).map(&:name))
      end
      refute(statements.any? { |sql| sql.include?("tin.score") || sql.include?("tin.tokenize") || sql.include?("==>") })
    ensure
      migration.migrate(:down)
    end
  end

  private

  def search(term, **options)
    Tinkick::Relation.new(SearchProduct, term, fields: [:name], match: :exact, misspellings: true, **options)
  end
end
