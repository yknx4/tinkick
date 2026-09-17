# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/model"

class TextSearchTest < TinkickIntegrationTest
  def test_whole_field_modes_work_through_models_and_relation_chaining
    model = search_model
    product = tinkick_test_products(:red_apple)
    product.update!(name: "Café of Rivendell")

    assert_equal([product.id], model.search("cafe of", match: :text_start, misspellings: false).map(&:id))
    assert_equal([product.id], model.search("of riven", misspellings: false).match(:text_middle).map(&:id))
    assert_equal([product.id], model.search("RIVENDELL", match: :text_end, misspellings: false).map(&:id))
    assert_empty(model.search("riven", match: :text_start, misspellings: false))
  end

  def test_whole_field_matching_keeps_native_filters_and_rejects_fuzzy_edits
    model = search_model
    product = tinkick_test_products(:red_apple)
    product.update!(name: "Rivendell travel journals")
    assert_raises(Tinkick::NotImplementedError) do
      model.search("rivendlel", match: :text_start, where: { id: product.id }).to_a
    end
    results = model.search("rivendell", match: :text_start, misspellings: false, where: { id: product.id })

    assert_equal([product.id], results.map(&:id))
    assert_equal(1, results.total_count)
    assert_equal([1.0], results.with_score.map { |_record, score| score })
    assert_empty(results.where(id: tinkick_test_products(:green_pear).id))
  end

  def test_mixed_whole_field_and_native_modes_preserve_both_paths
    first = tinkick_test_products(:red_apple)
    second = tinkick_test_products(:green_pear)
    first.update!(name: "Moria trail", description: "maps of distant Gondor")
    second.update!(name: "Unrelated atlas", description: "Moria caves")
    results = search_model.search("moria", fields: [{ name: :text_start }, :description], misspellings: false, order: :id)

    assert_equal([first.id, second.id].sort, results.map(&:id))
    assert_equal(2, results.total_count)
    assert_equal(1, results.countless.limit(1).size)
  end

  private

  def search_model
    Class.new(SearchProduct) do
      extend Tinkick::Model
      tinkick searchable: [:name]
    end
  end
end
