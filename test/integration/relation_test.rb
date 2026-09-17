# frozen_string_literal: true

require_relative "../../lib/tinkick/relation"
require_relative "../integration_helper"

class RelationTest < TinkickIntegrationTest
  class RawProjectionProduct < SearchProduct
    after_find { raise "raw projection must not instantiate a model" }
  end

  def test_construction_and_respond_to_are_lazy
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      search = relation("apple")
      assert_equal(SearchProduct, search.model)
      assert_equal(SearchProduct, search.klass)
      assert_respond_to(search, :total_count)
      assert_respond_to(search, :size)
      refute_respond_to(search, :missing_method)
      refute(search.loaded?)
    end
    assert_empty(statements)
  end

  def test_constructor_validates_options_without_execution
    assert_raises(ArgumentError) { Tinkick::Relation.new(SearchProduct, fields: [:name]) }
    assert_raises(ArgumentError) { Tinkick::Relation.new(SearchProduct, misspellings: false) }
    assert_raises(ArgumentError) { relation("apple", unknown_option: true) }
    assert_raises(ArgumentError) { relation("apple", fields: []) }
    assert_raises(ArgumentError) { relation("apple", limit: -1) }
  end

  def test_keyword_and_fluent_filters_are_equivalent
    keyword = relation("fruit", fields: [:description], where: { name: "Red Apple" }, order: { name: :desc }, limit: 1)
    fluent = relation("fruit", fields: [:description]).where(name: "Red Apple").order(name: :desc).limit(1)

    assert_equal(keyword.map(&:id), fluent.map(&:id))
    assert_equal(["Red Apple"], fluent.map(&:name))
  end

  def test_non_bang_modifiers_preserve_the_original
    original = relation.order(:name)
    limited = original.limit(1)

    assert_equal(["Green Pear"], limited.map(&:name))
    assert_equal(["Green Pear", "Red Apple"], original.map(&:name))
  end

  def test_bang_modifiers_return_self_and_reject_loaded_relations
    search = relation.order(:name)
    assert_same(search, search.limit!(1))
    assert_same(search, search.load)
    assert_same(search, search.load)
    assert(search.loaded?)
    assert_equal(["Green Pear"], search.map(&:name))

    { limit!: 2, offset!: 1, page!: 2, per_page!: 2, padding!: 1, where!: { name: "Red Apple" }, rewhere!: {}, fields!: :description, order!: :name, reorder!: :id, match!: :phrase, operator!: :or, misspellings!: false, load!: false }.each do |method, value|
      error = assert_raises(Tinkick::Error) { search.public_send(method, value) }
      assert_equal("Relation loaded", error.message)
    end
  end

  def test_clone_and_dup_are_unloaded_and_independent
    original = relation.order(:name).load
    copy = original.clone
    duplicate = original.dup

    refute(copy.loaded?)
    refute(duplicate.loaded?)
    copy.limit!(1)
    duplicate.where!(name: "Red Apple")
    assert_equal(["Green Pear"], copy.map(&:name))
    assert_equal(["Red Apple"], duplicate.map(&:name))
    assert_equal(2, original.size)
  end

  def test_repeated_where_combines_conditions_and_rewhere_replaces_them
    original = relation.where(name: "Red Apple")

    assert_empty(original.where(name: "Green Pear"))
    assert_empty(original.where("name" => "Green Pear"))
    assert_equal(["Red Apple"], original.where(description: "Fresh orchard fruit").map(&:name))
    assert_equal(["Green Pear"], original.rewhere(description: "Ripe fruit").map(&:name))
    assert_equal(["Green Pear"], relation.where.not(name: "Red Apple").map(&:name))
  end

  def test_fields_and_order_append_while_reorder_replaces
    search = relation("orchard")
    assert_equal(["Red Apple"], search.fields([:description]).map(&:name))
    assert_empty(search)

    search = relation.order(name: :desc)
    assert_equal(["Red Apple", "Green Pear"], search.order(:id).map(&:name))
    assert_equal(["Green Pear", "Red Apple"], search.reorder(:name).map(&:name))
  end

  def test_pagination_and_aliases
    search = relation.order(:name).page("2").per("1")

    assert_equal(["Red Apple"], search.map(&:name))
    assert_equal(2, search.current_page)
    assert_equal(1, search.per_page)
    assert_equal(1, search.limit_value)
    assert_equal(1, search.offset)
    assert_equal(1, search.offset_value)
    assert_equal(2, search.total_pages)
    assert_equal(2, search.num_pages)
    assert_equal(1, search.previous_page)
    assert_equal(1, search.prev_page)
    assert_nil(search.next_page)
    refute(search.first_page?)
    assert(search.last_page?)
    refute(search.out_of_range?)
    assert_equal(["Red Apple"], relation.order(:name).per_page(1).padding("1").map(&:name))
    assert_equal(1, relation.page(0).current_page)
    assert_equal(0, relation.padding(-1).padding)
  end

  def test_limit_wins_over_per_page_and_explicit_offset_wins_for_retrieval
    assert_equal(10_000, relation.per_page)
    assert_equal(1, relation.limit(1).per_page(2).per_page)
    search = relation.order(:name).offset(1).limit(1)

    assert_equal(["Red Apple"], search.map(&:name))
    assert_equal(0, search.offset_value)
  end

  def test_load_false_returns_wrappers_without_loading_the_original
    original = relation("apple")
    configured = original.load(false)
    refute(original.loaded?)
    refute(configured.loaded?)
    assert_instance_of(Tinkick::HashWrapper, configured.first)
    assert_instance_of(SearchProduct, original.load(nil).first)
  end

  def test_first_only_loads_a_limited_clone_and_respects_existing_limits
    original = relation.order(:name)

    assert_equal("Green Pear", original.first.name)
    refute(original.loaded?)
    assert_equal(["Green Pear"], original.first(1).map(&:name))
    assert_equal(1, original.limit(1).first(2).length)
    assert_empty(original.limit(0).first(2))
    assert_instance_of(SearchProduct, original.load.first)
  end

  def test_first_zero_is_empty_without_querying_for_countless_and_keyset
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      [:countless, :keyset].each do |mode|
        search = relation(limit: 2, **{ mode => true })

        assert_empty(search.first(0))
        refute(search.loaded?)
      end
    end
    assert_empty(statements)
  end

  def test_total_count_does_not_instantiate_records_and_count_counts_the_page
    search = relation.limit(1)
    instantiations = []
    callback = ->(_name, _start, _finish, _id, payload) { instantiations << payload[:record_count] }
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
      assert_equal(2, search.total_count)
      assert_empty(instantiations)
      assert(search.loaded?)
      assert_equal(1, search.count)
      assert_equal([1], instantiations)
    end
    assert_equal(7, relation(total_entries: 7).total_entries)
  end

  def test_match_operator_and_explicit_misspellings_modifiers
    assert_equal(["Red Apple"], relation("apple red").map(&:name))
    assert_empty(relation("apple red").match(:phrase))
    assert_equal(2, relation("apple pear").operator(:or).count)
    assert_equal(["Red Apple"], relation("appl").misspellings(transpositions: false).map(&:name))
  end

  def test_collection_and_score_delegation
    search = relation.order(:name)

    assert_equal(2, search.size)
    assert_equal(2, search.length)
    assert(search.any?)
    refute(search.empty?)
    assert_equal("Green Pear", search[0].name)
    assert_equal(1, search.slice(0, 1).length)
    assert_equal(2, search.to_ary.length)
    assert_equal(1, search.count { |record| record.name == "Red Apple" })
    assert_equal([1.0, 1.0], search.with_score.map { |_record, score| score })
  end

  def test_pluck_returns_scalar_and_tuple_shapes_from_the_bounded_page
    search = relation.order(:name).limit(1)
    expected_id = tinkick_test_products(:green_pear).id

    assert_equal(["Green Pear"], search.pluck(:name))
    assert(search.loaded?)
    statements = capture_queries do
      assert_equal([[expected_id, "Green Pear"]], search.pluck("id", :name))
    end
    assert_empty(statements)
    assert_equal(["Red Apple"], relation.order(:name).limit(1).page(2).pluck(:name))
  end

  def test_unloaded_raw_pluck_projects_columns_without_loading_the_original
    search = Tinkick::Relation.new(RawProjectionProduct, "*", fields: [:name], misspellings: false,
      load: false, order: :name, limit: 1)
    statements = capture_queries do
      assert_equal(["Green Pear"], search.pluck(:name))
    end

    refute(search.loaded?)
    sql = statements.find { |statement| statement.include?("AS _tinkick_score") }
    assert_includes(sql.split(" FROM ").first, '"name"')
    refute_includes(sql.split(" FROM ").first, ".*")
    assert_equal([[tinkick_test_products(:green_pear).id, "Green Pear"]], search.pluck(:id, "name"))
  end

  def test_raw_pluck_preserves_search_filters_pagination_and_probe_limits
    product = tinkick_test_products(:red_apple)
    search = relation("fruit", fields: [:description], load: false, order: :name, page: 2, per_page: 1)

    assert_equal(["Red Apple"], search.pluck(:name))
    assert_equal([product.id], relation("apple", load: false, where: { id: product.id }).pluck(:id))
    assert_equal(["Green Pear"], relation(load: false, countless: true, order: :name, limit: 1).pluck(:name))
    assert_empty(relation("unfindablezzzz", load: false).pluck(:name))
    assert_raises(Tinkick::MissingFieldError) { relation(load: false).pluck("name; SELECT 1") }
  end

  def test_loaded_raw_pluck_reuses_the_existing_page
    search = relation(load: false).order(:name).limit(1).load

    assert_empty(capture_queries { assert_equal(["Green Pear"], search.pluck(:name)) })
    assert(search.loaded?)
  end

  def test_raw_pluck_warns_about_migrating_to_model_results
    original_logger = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)

    relation(load: false).pluck(:name)
    assert_includes(output.string, "Migrate to model results")
    assert_includes(output.string, "both modes query PostgreSQL through Active Record")
  ensure
    SearchProduct.logger = original_logger
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  def relation(term = "*", **options)
    Tinkick::Relation.new(SearchProduct, term, fields: [:name], misspellings: false, **options)
  end
end
