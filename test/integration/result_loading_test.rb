# frozen_string_literal: true

require_relative "../integration_helper"

class ResultLoadingTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
    has_many :reviews, class_name: "ResultLoadingTest::Review", foreign_key: :product_id, inverse_of: :product
    has_one :first_review, -> { order(:id) }, class_name: "ResultLoadingTest::Review", foreign_key: :product_id
  end

  class Review < ActiveRecord::Base
    self.table_name = "tinkick_test_reviews"
    belongs_to :product, class_name: "ResultLoadingTest::Product", inverse_of: :reviews
  end

  set_fixture_class(tinkick_test_reviews: Review)
  fixtures :tinkick_test_reviews

  def test_keyword_includes_preloads_associations_without_n_plus_one_queries
    search = Product.search("*", includes: :reviews, order: :id)
    statements = capture_queries { search.load }

    assert_equal 1, statements.count { |sql| sql.include?('FROM "tinkick_test_reviews"') }
    assert search.all? { |product| product.association(:reviews).loaded? }
    assert_empty capture_queries { assert_equal ["Crisp", "Juicy", "Ripe"], search.flat_map { |product| product.reviews.map(&:body) }.sort }
  end

  def test_includes_preloads_only_visible_rows_after_the_countless_probe
    review_counts = []
    callback = ->(_name, _start, _finish, _id, payload) do
      review_counts << payload[:record_count] if payload[:class_name] == "ResultLoadingTest::Review"
    end
    search = Product.search("*", includes: [:reviews], order: :id, limit: 1, countless: true)

    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") { search.load }

    assert_equal [tinkick_test_products(:red_apple).id], search.map(&:id)
    assert_equal [2], review_counts
    assert search.has_next_page?
    assert_equal ["Crisp", "Juicy"], search.first.reviews.map(&:body).sort
  end

  def test_fluent_includes_accepts_nested_and_string_associations_without_mutating_source
    original = Product.search("*", order: :id)
    included = original.includes("reviews").includes(reviews: :product)

    assert included.all? { |product| product.association(:reviews).loaded? }
    assert included.flat_map(&:reviews).all? { |review| review.association(:product).loaded? }
    refute original.any? { |product| product.association(:reviews).loaded? }
    assert_empty capture_queries { included.each { |product| product.reviews.each { |review| review.product.name } } }
  end

  def test_includes_bang_accumulates_associations_and_rejects_loaded_changes
    search = Product.search("*", includes: :reviews, order: :id)

    assert_same search, search.includes!(:first_review)
    search.each do |product|
      assert product.association(:reviews).loaded?
      assert product.association(:first_review).loaded?
    end
    assert_raises(Tinkick::Error) { search.includes!(:reviews) }
  end

  def test_counts_do_not_load_associations_and_raw_results_ignore_includes
    search = Product.search("*", includes: :reviews)
    statements = capture_queries { assert_equal 2, search.total_count }

    refute statements.any? { |sql| sql.include?('FROM "tinkick_test_reviews"') }
    refute search.first.association(:first_review).loaded?
    raw = Product.search("*", includes: :reviews, load: false)
    statements = capture_queries { assert_equal 2, raw.length }
    assert_instance_of Tinkick::HashWrapper, raw.first
    refute statements.any? { |sql| sql.include?('FROM "tinkick_test_reviews"') }
  end

  def test_empty_search_does_not_query_associations
    search = Product.search("missing", misspellings: false, includes: :reviews)
    statements = capture_queries { assert_empty search }

    refute statements.any? { |sql| sql.include?('FROM "tinkick_test_reviews"') }
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
