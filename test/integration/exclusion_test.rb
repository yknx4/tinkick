# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/model"

class ExclusionTest < TinkickIntegrationTest
  class UseWhitespaceAnalysis < ActiveRecord::Migration[8.0]
    def up
      remove_index :tinkick_test_products, :name, using: :tin
      execute <<~SQL
        CREATE INDEX index_tinkick_test_products_on_name ON tinkick_test_products USING tin (name)
        WITH (tokenizer = whitespace, case_folding = preserve, accent_folding = preserve)
      SQL
      SearchProduct.reset_column_information
    end

    def down
      remove_index :tinkick_test_products, :name, using: :tin
      add_index :tinkick_test_products, :name, using: :tin
      SearchProduct.reset_column_information
    end
  end

  def test_excludes_exact_phrases_without_fuzzy_matching
    butter_names

    assert_equal(["Butter Tub"], search("butter", exclude: "peanut butter").map(&:name))
    assert_equal(["Butter Tub"], Tinkick.search("butter", model: @model, fields: [:name], exclude: "peanut butter").map(&:name))
    assert_equal(1, search("butter", exclude: ["peanut butter"]).total_count)
    assert_equal(2, search("butter", exclude: "peanut buttre", misspellings: true).total_count)
    assert_equal(["Butter Tub"], search("buttre", exclude: "peanut butter", misspellings: { edit_distance: 2 }).map(&:name))
  end

  def test_relation_chaining_appends_exclusions_and_preserves_the_original
    original = search("*")
    excluded = original.exclude("red apple").exclude(["green pear"], nil)

    assert_empty(excluded)
    assert_equal(2, original.total_count)
    assert_raises(Tinkick::Error) { excluded.exclude!("something") }
    assert_equal(2, search("*", exclude: nil).total_count)
    assert_equal(2, search("*", exclude: false).total_count)
    assert_equal(2, search("*", exclude: []).total_count)
  end

  def test_numeric_exclusions_are_analyzed_as_text
    tinkick_test_products(:red_apple).update!(name: "123")
    tinkick_test_products(:green_pear).update!(name: "456")

    assert_equal(["456"], search("*", exclude: 123).map(&:name))
    assert_equal(["123"], search("*", exclude: [456, "missing"]).map(&:name))
    assert_equal(["456"], search("*").exclude(123).map(&:name))
    assert_empty(search("*", exclude: 123).exclude(456))

    tinkick_test_products(:red_apple).update!(name: "1.5")
    assert_equal(["456"], search("*", match: :exact, exclude: 1.5).map(&:name))
  end

  def test_boolean_exclusions_are_text_except_the_false_option_sentinel
    tinkick_test_products(:red_apple).update!(name: "true")
    tinkick_test_products(:green_pear).update!(name: "false")

    assert_equal(["false"], search("*", exclude: true).map(&:name))
    assert_equal(["true"], search("*", exclude: [false]).map(&:name))
    assert_equal(2, search("*", exclude: false).total_count)
  end

  def test_invalid_exclusions_raise_instead_of_being_silently_ignored
    [Object.new, {}, [["apple"]], [nil], Float::INFINITY, Float::NAN].each do |value|
      error = assert_raises(ArgumentError) { search("*", exclude: value) }
      assert_includes(error.message, "exclude")
      assert_includes(error.message, "scalar")
    end
  end

  def test_exclusion_uses_every_selected_field_and_preserves_nulls
    apple = tinkick_test_products(:red_apple)
    pear = tinkick_test_products(:green_pear)
    apple.update!(name: "Butter", description: nil)
    pear.update!(name: "Butter", description: "Peanut butter")

    assert_equal(2, search("butter", fields: [:name], exclude: "peanut butter").total_count)
    result = search("butter", fields: [:name, :description], exclude: "peanut butter")
    assert_equal([apple.id], result.map(&:id))
    assert_equal(1, result.total_count)
    assert_equal([apple.id], search("*", fields: [:description], exclude: "peanut butter").map(&:id))
    assert_empty(search("butter", fields: [:name, :description], exclude: "peanut butter", where: { id: pear.id }))
  end

  def test_phrases_require_order_and_adjacency
    tinkick_test_products(:red_apple).update!(name: "Peanut Butter Tub")
    tinkick_test_products(:green_pear).update!(name: "Peanut Smooth Butter Tub")

    assert_equal(["Peanut Smooth Butter Tub"], search("butter", exclude: "peanut butter").map(&:name))
    assert_equal(2, search("butter", exclude: "butter peanut").total_count)
  end

  def test_partial_word_exclusions_are_adjacent_partial_phrases
    tinkick_test_products(:red_apple).update!(name: "Peanut Butter Tub")
    tinkick_test_products(:green_pear).update!(name: "Peanut Smooth Butter Tub")
    { word_start: "pea but", word_middle: "eanu utte", word_end: "nut ter" }.each do |mode, phrase|
      assert_equal(["Peanut Smooth Butter Tub"], search("butter", match: mode, exclude: phrase).map(&:name))
      assert_equal(2, search("butter", match: mode, exclude: phrase.split.reverse.join(" ")).total_count)
    end
  end

  def test_sql_match_modes_use_their_matching_normalization
    butter_names
    { text_start: "PEANUT", text_middle: "ANUT BUTT", text_end: "PEANUT BUTTER TUB" }.each do |mode, phrase|
      assert_equal(["Butter Tub"], search("*", match: mode, exclude: phrase).map(&:name))
    end
    assert_equal(["Butter Tub"], search("*", match: :exact, exclude: "Peanut Butter Tub").map(&:name))
    assert_equal(2, search("*", match: :exact, exclude: "peanut butter tub").total_count)
  end

  def test_mixed_sql_and_native_fields_exclude_globally
    apple = tinkick_test_products(:red_apple)
    pear = tinkick_test_products(:green_pear)
    apple.update!(name: "Butter", description: "Peanut butter")
    pear.update!(name: "Butter", description: "Plain dairy")
    result = search("Butter", fields: [{ name: :exact }, :description], exclude: "peanut butter")

    assert_equal([pear.id], result.map(&:id))
    assert_equal(1, result.total_count)
  end

  def test_empty_punctuation_and_tinql_syntax_are_literal_exclusions
    [nil, [], "", "!!!", "*", '") OR *'].each do |value|
      assert_equal(2, search("*", exclude: value).total_count)
    end
  end

  def test_json_scalar_exclusions_ignore_object_serialization
    apple = tinkick_test_products(:red_apple)
    pear = tinkick_test_products(:green_pear)
    apple.update!(metadata: { title: "Peanut butter" })
    pear.update!(metadata: { title: { text: "Peanut butter" } })

    assert_equal([pear.id], search("*", fields: ["metadata.title"], exclude: "peanut butter").map(&:id))
  end

  def test_exclusions_use_index_analysis_and_escape_partial_token_patterns
    migration = UseWhitespaceAnalysis.new
    migration.migrate(:up)
    begin
      tinkick_test_products(:red_apple).update!(name: "AND tag) Jalapeño")
      assert_equal(["Green Pear"], search("*", exclude: "AND tag)").map(&:name))
      assert_equal(2, search("*", exclude: "and tag)").total_count)
      assert_equal(2, search("*", exclude: "Jalapeno").total_count)
      assert_equal(["Green Pear"], search("*", match: :word_start, exclude: "tag)").map(&:name))
      assert_equal(2, search("*", match: :word_middle, exclude: '") OR *').total_count)
    ensure
      migration.migrate(:down)
    end
  end

  def test_keycap_phrases_and_long_partial_phrases_remain_literal
    tinkick_test_products(:red_apple).update!(name: "*️⃣ apple")
    assert_equal(["Green Pear"], search("*", exclude: "*️⃣ apple").map(&:name))
    assert_equal(["Green Pear"], search("*", match: :word_start, exclude: "*️⃣ ap").map(&:name))
    assert_equal(2, search("*", match: :word_start, exclude: "a" * 51).total_count)
  end

  def test_single_native_field_keeps_top_k_and_bound_query_text
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_equal(["Red Apple"], search("apple", exclude: "green pear", limit: 1).map(&:name))
    end
    statement = statements.find { |entry| entry[:sql].include?(" AS _tinkick_score") }
    refute_includes(statement.fetch(:sql), "green pear")
    values = statement.fetch(:binds).map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind }
    assert(values.any? { |value| value.is_a?(String) && value.include?("AND NOT") })
    plan = SearchProduct.connection.select_value(
      "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}",
      "Tinkick Exclusion Explain", statement.fetch(:binds),
    )
    assert_includes(plan, "Text Search Scan")
    assert_includes(plan, '"Top K": "1"')
    refute_includes(plan, '"Node Type": "Sort"')
  end

  private

  def butter_names
    tinkick_test_products(:red_apple).update!(name: "Butter Tub")
    tinkick_test_products(:green_pear).update!(name: "Peanut Butter Tub")
  end

  def search(term, **options)
    @model ||= Class.new(SearchProduct) { tinkick searchable: [:name] }
    @model.search(term, fields: [:name], misspellings: false, **options)
  end
end
