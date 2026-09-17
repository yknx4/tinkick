# frozen_string_literal: true

require_relative "../integration_helper"

class GlobalSearchTest < TinkickIntegrationTest
  class Product < SearchProduct
    class << self
      def search(*)
        "other search backend"
      end
    end

    tinkick searchable: [:name]
  end

  def test_explicit_model_uses_tinkick_without_replacing_existing_search
    assert_equal "other search backend", Product.search("apple")
    result = Tinkick.search("apple", model: Product, misspellings: false)

    assert_instance_of Tinkick::Relation, result
    assert_same Product, result.model
    refute_predicate result, :loaded?
    assert_equal ["Red Apple"], result.map(&:name)
    assert_equal 1, result.total_count
  end

  def test_default_term_and_options_follow_model_search
    result = Tinkick.search(model: Product, where: { name: { regexp: "Pear$" } },
      order: { id: :asc }, keyset: true, per_page: 1)

    assert_equal ["Green Pear"], result.map(&:name)
    assert_equal 1, result.total_count
    refute_predicate result, :has_next_page?
    assert_equal Product.tinkick_search("*").order(:id).pluck(:name), Tinkick.search(model: Product).order(:id).pluck(:name)
  end

  def test_chaining_and_raw_results_keep_the_existing_model_contract
    result = Tinkick.search("apple", model: Product, misspellings: false).load(false).limit(1)

    assert_instance_of Tinkick::HashWrapper, result.first
    assert_equal "Red Apple", result.first.name
    assert_equal Product.model_name, result.model_name
  end

  def test_registration_errors_remain_actionable
    error = assert_raises(Tinkick::Error) { Tinkick.search("apple", model: SearchProduct) }

    assert_includes error.message, "Declare tinkick"
  end
end
