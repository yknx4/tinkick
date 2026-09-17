# frozen_string_literal: true

require_relative "../integration_helper"

class DateAggregationMissingTest < TinkickIntegrationTest
  class Value < ActiveRecord::Base
    self.table_name = "tinkick_test_cursor_values"
    tinkick searchable: [:name]
    default_scope { where.not(name: "Hidden chronicle") }
  end

  setup do
    @first = Time.utc(2026, 1, 1, 12)
    @second = Time.utc(2026, 1, 2, 12)
    @third = Time.utc(2026, 1, 3, 12)
    arrays = [nil, [], [nil, nil], [@first, nil, @first, @third], [@second]]
    @records = arrays.each_with_index.map { |times, index| create_value("Missing date chronicle", index, times) }
    create_value("Unrelated archive", 90, nil)
    create_value("Hidden chronicle", 91, nil)
  end

  def test_date_ranges_replace_each_missing_array_once_and_deduplicate_documents
    page = search(events: range_options(missing: @second))
    result = page.aggs.fetch("events")

    assert_equal ["before", "middle", "after"], result.fetch("buckets").map { |bucket| bucket.fetch("key") }
    assert_equal [1, 4, 1], result.fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
    assert_equal 5, page.total_count
  end

  def test_calendar_histogram_replaces_null_empty_and_all_null_arrays_without_filling_populated_arrays
    buckets = histogram(missing: @second).fetch("buckets")

    assert_equal [1, 2, 3].map { |day| Time.utc(2026, 1, day).to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 4, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_fixed_histogram_counts_duplicate_values_and_joined_rows_once_per_document
    scope = Value.where("name ==> ?", "chronicle").joins("CROSS JOIN generate_series(1, 2) AS duplicate_rows")
    result = Tinkick::Aggregations.new(Value, scope.limit(1)).call(events: {
      date_histogram: { field: :recorded_times, fixed_interval: "24h", missing: @second, min_doc_count: 1 },
    }).fetch("events")

    assert_equal [1, 4, 1], result.fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
    refute scope.loaded?
  end

  def test_per_aggregation_filters_preserve_model_and_search_scopes_without_instantiating_rows
    options = { missing: @second, where: { price: { lt: 4 } } }
    instantiated = []
    ActiveSupport::Notifications.subscribed(->(*arguments) { instantiated << arguments.last[:record_count] }, "instantiation.active_record") do
      [ranges(**options), histogram(**options)].each do |result|
        assert_equal [1, 3, 1], result.fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
        assert_equal 4, result.fetch("doc_count")
      end
    end

    assert_empty instantiated
  end

  def test_empty_filtered_scopes_do_not_invent_fallback_documents
    assert_equal [0, 0, 0], ranges(missing: @second, where: { id: -1 }).fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
    assert_empty histogram(missing: @second, where: { id: -1 }).fetch("buckets")
  end

  def test_nil_missing_preserves_ordinary_date_range_and_histogram_results
    assert_equal ranges, ranges(missing: nil)
    assert_equal histogram, histogram(missing: nil)
    assert_equal [1, 1, 1], ranges(missing: nil).fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
  end

  def test_non_null_date_and_datetime_columns_keep_existing_values
    [:recorded_on, :recorded_at].each do |field|
      options = { field: field, date_ranges: [{ to: "2040-01-01" }, { from: "2040-01-01" }] }

      assert_equal ranges(**options), ranges(**options, missing: "2040-01-01")
      assert_equal [5, 0], ranges(**options, missing: "2040-01-01").fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
      assert_equal histogram(field: field), histogram(field: field, missing: "2040-01-01")
    end
  end

  def test_date_range_missing_values_use_the_configured_timezone_for_iso_inputs
    instant = Time.utc(2026, 1, 2, 5, 30)
    ["2026-01-02T00:30:00", "2026-01-02T00:30:00-05:00", instant, instant.to_i * 1_000].each do |missing|
      result = ranges(missing: missing, time_zone: "America/New_York", where: { id: @records.first(3).map(&:id) },
        date_ranges: [{ key: "local day", from: "2026-01-02", to: "2026-01-03" }])
      bucket = result.fetch("buckets").first

      assert_equal 3, bucket.fetch("doc_count"), missing.inspect
      assert_equal Time.utc(2026, 1, 2, 5).to_i * 1_000, bucket.fetch("from")
      assert_equal "2026-01-02T00:00:00.000-05:00", bucket.fetch("from_as_string")
    end
  end

  def test_calendar_missing_iso_epoch_and_time_inputs_share_the_same_local_bucket
    instant = Time.utc(2026, 1, 2, 5, 30)
    ["2026-01-02T00:30:00", instant, instant.to_i * 1_000].each do |missing|
      buckets = histogram(missing: missing, time_zone: "America/New_York", where: { id: @records.first(3).map(&:id) }).fetch("buckets")

      assert_equal [{ "key" => Time.utc(2026, 1, 2, 5).to_i * 1_000,
                      "key_as_string" => "2026-01-02T00:00:00.000-05:00", "doc_count" => 3 }], buckets, missing.inspect
    end
  end

  def test_fixed_missing_iso_epoch_and_time_inputs_use_native_offset_origin
    instant = Time.utc(2026, 1, 2, 5, 30)
    key = Time.utc(2026, 1, 2, 5).to_i * 1_000
    ["2026-01-02T06:30:00", instant, instant.to_i * 1_000].each do |missing|
      buckets = histogram(missing: missing, fixed_interval: "2h", time_zone: "+01:00",
        format: "epoch_millis", where: { id: @records.first(3).map(&:id) }).fetch("buckets")

      assert_equal [{ "key" => key, "key_as_string" => key.to_s, "doc_count" => 3 }], buckets, missing.inspect
    end
  end

  def test_nullable_date_fallback_preserves_calendar_dates_across_bucket_timezones
    date = Date.new(2026, 1, 2)
    @records.first.update!(recorded_date: date)
    replacements = [date, "2026-01-02", "2026-01-02T00:30:00+14:00", Time.new(2026, 1, 2, 0, 30, 0, "+14:00")]
    { "+14:00" => Time.utc(2026, 1, 1, 10), "-12:00" => Time.utc(2026, 1, 1, 12) }.each do |zone, bucket_time|
      replacements.each do |missing|
        buckets = histogram(field: :recorded_date, missing: missing, time_zone: zone).fetch("buckets")

        assert_equal [bucket_time.to_i * 1_000], buckets.map { |bucket| bucket.fetch("key") }, "#{zone}: #{missing.inspect}"
        assert_equal [5], buckets.map { |bucket| bucket.fetch("doc_count") }
      end
    end
  end

  def test_nullable_date_epoch_fallback_uses_the_utc_calendar_date
    @records.first.update!(recorded_date: Date.new(2026, 1, 2))
    missing = Time.utc(2026, 1, 2, 0, 30).to_i * 1_000
    { "+14:00" => Time.utc(2026, 1, 1, 10), "-12:00" => Time.utc(2026, 1, 1, 12) }.each do |zone, bucket_time|
      buckets = histogram(field: :recorded_date, missing: missing, time_zone: zone).fetch("buckets")

      assert_equal [bucket_time.to_i * 1_000], buckets.map { |bucket| bucket.fetch("key") }, zone
      assert_equal [5], buckets.map { |bucket| bucket.fetch("doc_count") }
    end
  end

  def test_nullable_date_ranges_preserve_existing_dates_and_replace_only_null_rows
    @records.first.update!(recorded_date: Date.new(2026, 1, 3))
    result = ranges(field: :recorded_date, missing: "2026-01-02T00:30:00+14:00", date_ranges: [
      { from: Date.new(2026, 1, 2), to: Date.new(2026, 1, 3) }, { from: Date.new(2026, 1, 3) },
    ])

    assert_equal [4, 1], result.fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
  end

  def test_invalid_missing_dates_and_elasticsearch_date_math_fail_clearly
    ["not-a-date", "2026-02-30", false, Float::INFINITY].each do |missing|
      [:ranges, :histogram].each do |aggregation|
        error = assert_raises(ArgumentError) { send(aggregation, missing: missing) }
        assert_match(/date|bound|epoch/i, error.message)
      end
    end
    ["now-1d", "2026-01-01||/d"].each do |missing|
      [:ranges, :histogram].each do |aggregation|
        error = assert_raises(Tinkick::NotImplementedError) { send(aggregation, missing: missing) }
        assert_match(/date math/i, error.message)
        assert_match(/Time|Date/, error.message)
      end
    end
  end

  def test_missing_never_masks_an_unknown_field_or_accepts_the_wrong_option_placement
    assert_raises(Tinkick::MissingFieldError) { ranges(field: :absent, missing: @second) }
    assert_raises(Tinkick::MissingFieldError) { histogram(field: :absent, missing: @second) }
    assert_raises(ArgumentError) { ranges(date_ranges: [{ from: @first, missing: @second }]) }
    assert_raises(ArgumentError) do
      search(events: { missing: @second, date_histogram: { field: :recorded_times, calendar_interval: :day } }).aggs
    end
  end

  private

  def create_value(name, index, times)
    Value.create!(name: name, code: format("00000000-0000-0000-0000-%012d", index), recorded_on: @first.to_date,
      recorded_at: @first, recorded_times: times, price: index)
  end

  def search(**aggregations)
    Value.search("chronicle", fields: [:name], misspellings: false, limit: 1, aggs: aggregations)
  end

  def range_options(**options)
    { field: :recorded_times, date_ranges: [{ key: "before", to: @second },
                                         { key: "middle", from: @second, to: @third }, { key: "after", from: @third }] }.merge(options)
  end

  def ranges(**options)
    search(events: range_options(**options)).aggs.fetch("events")
  end

  def histogram(where: nil, **options)
    settings = { field: :recorded_times, min_doc_count: 1 }.merge(options)
    settings[:calendar_interval] = :day unless settings.key?(:fixed_interval)
    search(events: { where: where, date_histogram: settings }).aggs.fetch("events")
  end
end
