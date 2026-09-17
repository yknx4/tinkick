# frozen_string_literal: true

require_relative "../integration_helper"

class AggregationTermFiltersTest < TinkickIntegrationTest
  class Product < SearchProduct
    default_scope { where(id: 21_001..21_005) }
    tinkick searchable: [:description]
  end

  setup do
    [
      ["Shire", "Moria", "Shire"],
      ["Shire", "Lindon"],
      ["Moria", "Rivendell"],
      ["Westshire", "Isengard"],
      ["Shire", "Gondor"],
      ["Mordor"],
    ].each_with_index do |tags, index|
      SearchProduct.create!(id: 21_001 + index, name: "Region #{index}",
        description: index == 4 ? "Unrelated archive" : "Mithrilatlas expedition",
        tags: tags, ratings: [index + 1, index + 1, index + 2])
    end
  end

  def test_exact_lists_filter_each_array_value_without_discarding_its_document
    page = search(include: ["Shire", "Moria"])

    assert_equal({ "Shire" => 2, "Moria" => 2 }, buckets(page))
    assert_equal 4, page.total_count
    assert_equal 4, page.map(&:id).size
  end

  def test_exclude_wins_for_values_accepted_by_include
    assert_equal({ "Moria" => 2, "Rivendell" => 1 }, buckets(search(include: ["Shire", "Moria", "Rivendell"], exclude: ["Shire"])))
    assert_equal({ "Westshire" => 1 }, buckets(search(include: "(?i)shire", exclude: "^Shire$")))
  end

  def test_empty_lists_have_set_semantics
    assert_empty buckets(search(include: []))
    assert_equal buckets(search), buckets(search(exclude: []))
    assert_empty buckets(search(include: [], exclude: []))
  end

  def test_native_regex_is_unanchored_accepts_embedded_flags_and_warns
    output = StringIO.new
    previous = Product.logger
    Product.logger = Logger.new(output, level: Logger::WARN)

    assert_equal({ "Shire" => 2, "Westshire" => 1 }, buckets(search(include: "(?i)shire")))
    assert_equal({ "Shire" => 2 }, buckets(search(include: "^Shire$")))
    assert_includes output.string, "PostgreSQL regex"
    assert_includes output.string, "aggregation"
  ensure
    Product.logger = previous
  end

  def test_exact_values_and_regex_patterns_remain_bound
    literal = "Shire' OR TRUE --"
    SearchProduct.where(id: 21_001).update_all(tags: [literal, "Moria"])
    [[literal], "^Shire' OR TRUE --$"].each do |filter|
      statements = []
      callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        assert_equal({ literal => 1 }, buckets(search(include: filter)))
      end
      statement = statements.find { |entry| entry.fetch(:sql).include?("_tinkick_total") }
      refute_nil statement
      expected = filter.is_a?(Array) ? literal : filter
      refute_includes statement.fetch(:sql), expected
      assert_includes statement.fetch(:binds).map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind }, expected
    end
    assert_equal 6, SearchProduct.where(id: 21_001..21_006).count
  end

  def test_numeric_value_lists_preserve_native_column_values
    page = Product.search("mithrilatlas", misspellings: false,
      aggs: { selected: { field: :ratings, include: [2, 3, 4], exclude: [3] } })

    assert_equal({ 2 => 2, 4 => 2 }, buckets(page))
  end

  def test_zero_count_dictionary_filters_values_and_preserves_model_scope
    page = search(min_doc_count: 0, include: ["Shire", "Gondor", "Mordor"], exclude: ["Shire"])

    assert_equal({ "Gondor" => 0 }, buckets(page))
    assert_equal 0, page.aggs.fetch("selected").fetch("sum_other_doc_count")
    assert_equal({ "Gondor" => 0 }, buckets(search(min_doc_count: 0, include: "dor$")))
  end

  def test_limits_and_other_counts_apply_after_term_filters_without_instantiation
    page = search(include: ["Shire", "Moria", "Lindon", "Rivendell"], exclude: ["Moria"], limit: 1,
      where: { ratings: { gt: 0 } })
    instantiations = []
    callback = ->(_name, _start, _finish, _id, payload) { instantiations << payload.fetch(:record_count) }
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
      assert_equal({ "Shire" => 2 }, buckets(page))
    end

    assert_empty instantiations
    assert_equal 2, page.aggs.fetch("selected").fetch("sum_other_doc_count")
    assert_equal 4, page.aggs.fetch("selected").fetch("doc_count")
    assert_equal 0, page.aggs.fetch("selected").fetch("doc_count_error_upper_bound")
  end

  def test_term_filters_are_rejected_on_non_terms_aggregations
    [
      { sum: { field: :ratings } },
      { field: :ratings, ranges: [{ from: 0 }] },
      { field: :ratings, date_ranges: [{}] },
      { histogram: { field: :ratings, interval: 1 } },
      { date_histogram: { field: :ratings, calendar_interval: "day" } },
    ].each do |options|
      [:include, :exclude].each do |kind|
        error = assert_raises(ArgumentError) { search(**options, kind => []).aggs }
        assert_includes error.message, "include and exclude apply only to terms aggregations"
      end
    end
  end

  def test_ruby_regex_and_elasticsearch_partition_hashes_have_actionable_errors
    [:include, :exclude].each do |kind|
      error = assert_raises(Tinkick::NotImplementedError) { search(kind => /shire/i).aggs }
      assert_includes error.message, "PostgreSQL regex string"
      error = assert_raises(Tinkick::NotImplementedError) { search(kind => { partition: 0, num_partitions: 2 }).aggs }
      assert_includes error.message, "partition"
      assert_includes error.message, "where"
    end
  end

  def test_invalid_native_regex_errors_come_from_postgresql
    error = assert_raises(ActiveRecord::StatementInvalid) { search(include: "[").aggs }

    assert_instance_of PG::InvalidRegularExpression, error.cause
  end

  private

  def search(**options)
    Product.search("mithrilatlas", misspellings: false, aggs: { selected: { field: :tags, **options } })
  end

  def buckets(page)
    page.aggs.fetch("selected").fetch("buckets").to_h { |bucket| [bucket.fetch("key"), bucket.fetch("doc_count")] }
  end
end
