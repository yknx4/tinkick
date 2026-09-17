# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/model"

class FieldMatchingTest < TinkickIntegrationTest
  def test_distinct_native_modes_keep_boolean_terms_within_each_field
    assert_equal(["Red Apple"], search("app", fields: [{ name: :word_start }, { description: :phrase }]).map(&:name))
    assert_equal(["Green Pear"], search("ripe fruit", fields: [{ name: :exact }, { description: :phrase }]).map(&:name))
    assert_empty(search("red orchard", fields: [{ name: :word }, { description: :word_start }]))
  end

  def test_mixed_exact_and_native_matching_preserves_every_match_and_deduplicates
    apple = tinkick_test_products(:red_apple)
    pear = tinkick_test_products(:green_pear)
    apple.update!(name: "Moria", description: "Moria Moria")
    pear.update!(name: "Moria", description: "unrelated orchard")
    expected = [apple.id, pear.id].sort
    results = search("Moria", fields: [{ name: :exact }, :description], order: :id)

    assert_equal(expected, results.map(&:id))
    assert_equal(2, results.total_count)
    assert_equal(expected.last(1), results.limit(1).offset(1).map(&:id))
    assert_equal([apple.id], search("Moria", fields: [{ name: :exact }, :description], where: { id: apple.id }).map(&:id))
    assert_equal([apple.id], search("moria", fields: [{ name: :exact }, :description]).map(&:id))
  end

  def test_mixed_scoring_comes_from_tin_plus_exact_field_matches
    apple = tinkick_test_products(:red_apple)
    pear = tinkick_test_products(:green_pear)
    apple.update!(name: "Moria", description: "Moria Moria")
    pear.update!(name: "Gondor", description: "Moria travel maps and historical chronicles")
    results = search("Moria", fields: [{ name: :exact }, :description])

    scores = results.with_score.to_a.to_h { |record, score| [record.id, score] }
    assert_operator(scores.fetch(apple.id), :>, scores.fetch(pear.id))
    assert_equal([apple.id, pear.id], results.map(&:id))
  end

  def test_field_hashes_work_through_model_registration_and_relation_chaining
    model = Class.new(SearchProduct) do
      extend Tinkick::Model
      tinkick searchable: [:name, :description]
    end
    results = model.search("Red Apple", fields: [{ name: :exact }], misspellings: false)

    assert_equal(["Red Apple"], results.map(&:name))
    assert_equal(["Red Apple"], model.search("app", misspellings: false).fields(name: :word_start).map(&:name))
    assert_equal(["Red Apple"], search("Red Apple", fields: [{ name: :exact }, { name: :phrase }]).map(&:name))
  end

  def test_mixed_values_stay_bound_and_invalid_field_specs_fail
    product = tinkick_test_products(:red_apple)
    term = "x' OR 1=1 --"
    product.update!(name: term)
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_equal([product.id], search(term, fields: [{ name: :exact }, :description]).map(&:id))
    end
    statement = statements.find { |entry| entry[:sql].include?("_tinkick_ranked") }
    refute_nil(statement)
    refute_includes(statement.fetch(:sql), term)
    assert_includes(statement.fetch(:binds).map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind }, term)

    assert_raises(ArgumentError) { search("apple", fields: [{}]).to_a }
    assert_raises(ArgumentError) { search("apple", fields: [{ name: :word, description: :exact }]).to_a }
    assert_raises(Tinkick::MissingFieldError) { search("apple", fields: [{ "name; SELECT 1" => :exact }]).to_a }
  end

  def test_costly_matching_paths_warn_when_results_are_loaded
    original_logger = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)
    mixed = search("Red Apple", fields: [{ name: :exact }, :description])
    assert_empty(output.string)
    mixed.to_a
    assert_includes(output.string, "mixed TIN and SQL")
    assert_includes(output.string, "group matching rows")

    output.truncate(0)
    output.rewind
    assert_raises(Tinkick::NotImplementedError) { search("apxl", match: :word_start, misspellings: true).to_a }
    assert_empty(output.string)
  ensure
    SearchProduct.logger = original_logger
  end

  private

  def search(term, **options)
    Tinkick::Relation.new(SearchProduct, term, fields: [:name], misspellings: false, **options)
  end
end
