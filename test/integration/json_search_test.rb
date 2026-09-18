# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/model"

class JsonSearchTest < TinkickIntegrationTest
  HOSTILE_KEY = %q[quoted'key\"); DROP TABLE ignored; --]

  class CreateUnusableJsonIndexes < ActiveRecord::Migration[8.0]
    def change
      add_index :tinkick_test_products, "(metadata ->> 'unindexed')", using: :tin,
        where: "metadata IS NOT NULL", name: :tinkick_test_products_json_partial_tin
      add_index :tinkick_test_products, "lower(metadata ->> 'transformed')", using: :tin,
        name: :tinkick_test_products_json_transformed_tin
    end
  end

  def test_searches_indexed_scalar_paths_and_observes_changes_immediately
    apple = tinkick_test_products(:red_apple)
    pear = tinkick_test_products(:green_pear)
    apple.update!(metadata: { title: "Ruby orchard", details: { title: "Apple history" }, other: "PostgreSQL" })
    pear.update!(metadata: { title: "PostgreSQL garden", details: { title: "Pear history" }, other: "Ruby" })

    assert_equal(["Red Apple"], search("ruby").map(&:name))
    assert_equal(["Green Pear"], search("postgresql").map(&:name))
    assert_equal(["Red Apple"], search("apple", fields: ["metadata.details.title"]).map(&:name))
    apple.update!(metadata: { title: "Elixir orchard" })
    assert_empty(search("ruby"))
    assert_equal(["Red Apple"], search("elixir").map(&:name))
  end

  def test_null_missing_and_nonscalar_paths_do_not_match
    apple = tinkick_test_products(:red_apple)
    pear = tinkick_test_products(:green_pear)
    [nil, {}, { title: nil }, { title: ["orchard"] }, { title: { orchard: "orchard" } }].each do |metadata|
      apple.update!(metadata: metadata)
      pear.update!(metadata: { unrelated: "orchard" })

      assert_empty(search("orchard"), metadata.inspect)
    end
  end

  def test_numbers_and_booleans_use_their_scalar_text_representation
    tinkick_test_products(:red_apple).update!(metadata: { title: 42 })
    tinkick_test_products(:green_pear).update!(metadata: { title: true })

    assert_equal(["Red Apple"], search("42").map(&:name))
    assert_equal(["Green Pear"], search("true").map(&:name))
  end

  def test_quoted_path_keys_and_search_terms_are_safe
    product = tinkick_test_products(:red_apple)
    term = "x' OR 1=1 --"
    product.update!(metadata: { HOSTILE_KEY => term })
    statements = capture_queries do
      assert_equal([product.id], search(term, fields: ["metadata.#{HOSTILE_KEY}"]).map(&:id))
    end
    statement = statements.find { |entry| entry[:sql].include?(" AS _tinkick_score") }

    refute_nil(statement)
    refute_includes(statement.fetch(:sql), term)
    assert(SearchProduct.connection.table_exists?("tinkick_test_products"))
    assert_raises(ArgumentError) { search("orchard", fields: ["metadata..title"]) }
    assert_raises(ArgumentError) { search("orchard", fields: ["metadata.\0title"]) }
  end

  def test_mixed_native_and_sql_fields_keep_filters_and_counts
    apple = tinkick_test_products(:red_apple)
    pear = tinkick_test_products(:green_pear)
    apple.update!(metadata: { title: "Rivendell orchard" })
    pear.update!(metadata: { title: "Pear garden" })
    fields = [:name, "metadata.title"]

    assert_equal(["Green Pear", "Red Apple"], search("pear rivendell", fields: fields, operator: :or, order: :name).map(&:name))
    assert_equal([apple.id], search("pear rivendell", fields: fields, operator: :or, where: { id: apple.id }).map(&:id))
    results = search("Red Apple", fields: [{ name: :exact }, "metadata.title"])
    assert_equal([apple.id], results.map(&:id))
    assert_equal(1, results.total_count)
    assert_equal([apple.id], search("Riven", fields: [{ "metadata.title" => :text_start }]).map(&:id))
  end

  def test_json_paths_require_a_real_nonarray_jsonb_root
    assert_raises(Tinkick::MissingFieldError) { search("apple", fields: ["absent.title"]) }
    assert_raises(Tinkick::InvalidQueryError) { search("apple", fields: ["name.title"]) }
    assert_raises(Tinkick::InvalidQueryError) { search("apple", fields: ["tags.title"]) }
  end

  def test_missing_expression_index_reports_the_generator
    error = assert_raises(Tinkick::Error) { search("apple", fields: ["metadata.unindexed"]) }

    assert_includes(error.message, "tinkick:index")
    assert_includes(error.message, "metadata.unindexed")
  end

  def test_partial_or_different_expressions_do_not_satisfy_the_index_contract
    migration = CreateUnusableJsonIndexes.new
    migration.migrate(:up)
    begin
      ["metadata.unindexed", "metadata.transformed"].each do |field|
        error = assert_raises(Tinkick::Error) { search("apple", fields: [field]) }

        assert_includes(error.message, "valid, nonpartial TIN expression index")
      end
    ensure
      migration.migrate(:down)
    end
  end

  def test_tinkick_search_data_still_validates_physical_columns_on_a_new_instance
    invalid = Class.new(SearchProduct) do
      tinkick searchable: ["metadata.title"]
      def tinkick_search_data
        { "metadata.title" => nil }
      end
    end
    assert_raises(Tinkick::MissingFieldError) { invalid.search("apple") }
    tinkick_test_products(:red_apple).update!(metadata: { title: "Orchard" })
    valid = Class.new(SearchProduct) do
      tinkick searchable: ["metadata.title"]
      def tinkick_search_data
        { metadata: metadata }
      end
    end

    assert_equal(["Red Apple"], valid.search("orchard", misspellings: false).map(&:name))
  end

  def test_generated_expression_index_remains_in_the_real_query_plan
    tinkick_test_products(:red_apple).update!(metadata: { title: "Rivendell orchard" })
    statements = capture_queries { assert_equal(["Red Apple"], search("rivendell", limit: 1).map(&:name)) }
    statement = statements.find { |entry| entry[:sql].include?(" AS _tinkick_score") }
    plan = SearchProduct.connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}", "Tinkick JSON Explain", statement.fetch(:binds))

    require_production_tin_plan!
    assert_includes(plan, "Text Search Scan")
    assert_includes(plan, "tinkick_test_products_metadata_title_tin")
    refute_includes(plan, '"Node Type": "Seq Scan"')
  end

  private

  def search(term, **options)
    @search_model ||= Class.new(SearchProduct) { tinkick searchable: ["metadata.title"] }
    @search_model.search(term, fields: ["metadata.title"], misspellings: false, **options)
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
