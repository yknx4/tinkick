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

  def test_model_includes_combines_current_model_associations_with_generic_includes
    search = Product.search("*", includes: :reviews, model_includes: { Product => :first_review, Review => :unknown }, order: :id)

    search.each do |product|
      assert product.association(:reviews).loaded?
      assert product.association(:first_review).loaded?
    end
    assert_empty capture_queries { search.each { |product| product.first_review.body } }
  end

  def test_fluent_model_includes_merges_mappings_without_mutating_source
    original = Product.search("*").model_includes(Product => :reviews)
    included = original.model_includes(Review => :unknown).model_includes(Product => :first_review)

    assert included.all? { |product| product.association(:first_review).loaded? }
    refute included.any? { |product| product.association(:reviews).loaded? }
    assert original.all? { |product| product.association(:reviews).loaded? }
    refute original.any? { |product| product.association(:first_review).loaded? }
  end

  def test_model_includes_bang_returns_self_and_rejects_loaded_changes
    search = Product.search("*")

    assert_same search, search.model_includes!(Product => :reviews)
    assert search.all? { |product| product.association(:reviews).loaded? }
    assert_raises(Tinkick::Error) { search.model_includes!(Product => :first_review) }
  end

  def test_raw_results_ignore_model_includes
    search = Product.search("*", load: false, model_includes: { Product => :unknown })
    statements = capture_queries { assert_equal 2, search.length }

    assert_instance_of Tinkick::HashWrapper, search.first
    refute statements.any? { |sql| sql.include?('FROM "tinkick_test_reviews"') }
  end

  def test_scope_results_filters_only_the_ranked_page_without_changing_totals
    callback = ->(records) { records.where(name: "Green Pear") }
    first = Product.search("*", order: :id, limit: 1, scope_results: callback)
    second = Product.search("*", order: :id, limit: 1, page: 2, scope_results: callback)

    assert_empty first
    assert_equal 2, first.total_count
    assert_equal 2, first.next_page
    assert_equal ["Green Pear"], second.map(&:name)
    assert_equal 2, second.total_count
  end

  def test_scope_results_preserves_search_order_scores_and_association_loading
    search = Product.search("*", order: :id, includes: :reviews, scope_results: ->(records) { records.order(name: :asc) })

    assert_equal ["Red Apple", "Green Pear"], search.map(&:name)
    assert_equal [1.0, 1.0], search.with_score.map { |_record, score| score }
    assert search.all? { |product| product.association(:reviews).loaded? }
    assert_empty capture_queries { search.each { |product| product.reviews.map(&:body) } }
  end

  def test_scope_results_is_lazy_cached_and_ignored_for_raw_results
    calls = 0
    callback = ->(records) {
                 calls += 1
                 records.where(name: "Red Apple") }
    search = Product.search("*", scope_results: callback)

    assert_equal 2, search.total_count
    assert_equal 0, calls
    assert_equal ["Red Apple"], search.map(&:name)
    assert_empty capture_queries { search.with_score.to_a }
    assert_equal 1, calls
    assert_equal 2, Product.search("*", load: false, scope_results: callback).length
    assert_equal 1, calls
  end

  def test_scope_results_does_not_instantiate_excluded_page_records
    instantiations = []
    listener = ->(_name, _start, _finish, _id, payload) { instantiations << payload[:record_count] }
    search = Product.search("*", limit: 1, order: :id, scope_results: ->(records) { records.where(name: "Green Pear") })

    ActiveSupport::Notifications.subscribed(listener, "instantiation.active_record") { assert_empty search }

    assert_equal 0, instantiations.sum
  end

  def test_scope_results_cannot_expand_the_search_page_or_remove_search_filters
    callback = ->(records) { records.unscope(:where) }
    search = Product.search("*", where: { name: "Red Apple" }, scope_results: callback)

    assert_equal ["Red Apple"], search.map(&:name)
    assert_equal 1, search.total_count
  end

  def test_fluent_scope_results_preserves_source_and_supports_loaded_guards
    original = Product.search("*")
    callback = ->(records) { records.where(name: "Red Apple") }
    filtered = original.scope_results(callback)

    assert_equal ["Red Apple"], filtered.map(&:name)
    assert_equal 2, original.length
    assert_raises(Tinkick::Error) { filtered.scope_results!(callback) }
    changed = Product.search("*")
    assert_same changed, changed.scope_results!(callback)
    assert_equal 2, changed.scope_results(nil).length
    assert_equal ["Red Apple"], changed.map(&:name)
  end

  def test_scope_results_preserves_keyset_navigation_when_a_page_is_filtered_empty
    callback = ->(records) { records.where(name: "Green Pear") }
    first = Product.search("*", keyset: true, limit: 1, scope_results: callback)

    assert_empty first
    assert first.has_next_page?
    refute first.out_of_range?
    refute_nil first.next_cursor
    second = Product.search("*", keyset: true, after: first.next_cursor, limit: 1, scope_results: callback)
    assert_equal ["Green Pear"], second.map(&:name)
    refute second.has_next_page?
  end

  def test_scope_results_warns_once_about_extra_query_and_unchanged_totals
    original_logger = Product.logger
    output = StringIO.new
    Product.logger = Logger.new(output)
    search = Product.search("*", scope_results: ->(records) { records.where(name: "Red Apple") })

    search.to_a
    search.to_a

    assert_equal 1, output.string.scan("scope_results runs a second").length
    assert_includes output.string, "page-bounded"
    assert_includes output.string, "total_count"
    assert_includes output.string, "where:"
  ensure
    Product.logger = original_logger
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
