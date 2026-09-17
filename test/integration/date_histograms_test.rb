# frozen_string_literal: true

require_relative '../integration_helper'

class DateHistogramValue < ActiveRecord::Base
  self.table_name = 'tinkick_test_cursor_values'
end

class DateHistogramsTest < TinkickIntegrationTest
  setup do
    [Time.utc(2024, 1, 15, 12, 34, 56), Time.utc(2024, 2, 1), Time.utc(2024, 2, 29, 23, 59, 59.999), Time.utc(2024, 4, 1)].each_with_index do |instant, index|
      DateHistogramValue.create!(name: 'Calendar observation', code: format('00000000-0000-0000-0000-%012d', index),
        recorded_on: instant.to_date, recorded_at: instant, price: index)
    end
    DateHistogramValue.create!(name: 'Unrelated archive', code: '00000000-0000-0000-0000-000000000099',
      recorded_on: Date.new(2025, 1, 1), recorded_at: Time.utc(2025, 1, 1), price: 99)
    @scope = DateHistogramValue.where('name ==> ?', 'observation')
  end

  def test_public_calendar_month_histogram_counts_all_matches_and_fills_empty_months
    search = Tinkick::Relation.new(DateHistogramValue, 'observation', fields: [:name], misspellings: false, limit: 1,
      aggs: { events: { date_histogram: { field: :recorded_at, calendar_interval: :month } } })
    instantiated = []
    result = nil
    ActiveSupport::Notifications.subscribed(->(*arguments) { instantiated << arguments.last[:record_count] }, 'instantiation.active_record') do
      result = search.aggs.fetch('events').fetch('buckets')
    end

    assert_equal [1, 2, 3, 4].map { |month| Time.utc(2024, month, 1).to_i * 1_000 }, result.map { |bucket| bucket.fetch('key') }
    assert_equal([1, 2, 0, 1], result.map { |bucket| bucket.fetch('doc_count') })
    assert_equal '2024-02-01T00:00:00.000Z', result.fetch(1).fetch('key_as_string')
    assert_empty instantiated
  end

  def test_calendar_units_and_aliases_round_the_leap_day_and_week_starts_monday
    scope = @scope.where(recorded_on: Date.new(2024, 2, 29))
    expected = {
      year: Time.utc(2024, 1, 1), quarter: Time.utc(2024, 1, 1), month: Time.utc(2024, 2, 1), week: Time.utc(2024, 2, 26),
      day: Time.utc(2024, 2, 29), hour: Time.utc(2024, 2, 29, 23), minute: Time.utc(2024, 2, 29, 23, 59), second: Time.utc(2024, 2, 29, 23, 59, 59),
    }
    aliases = { year: '1y', quarter: '1q', month: '1M', week: '1w', day: '1d', hour: '1h', minute: '1m', second: '1s' }
    expected.each do |unit, instant|
      buckets = histogram(scope: scope, calendar_interval: unit).fetch('buckets')

      assert_equal [{ 'key' => instant.to_i * 1_000, 'key_as_string' => instant.iso8601(3), 'doc_count' => 1 }], buckets
      assert_equal buckets, histogram(scope: scope, calendar_interval: aliases.fetch(unit)).fetch('buckets')
    end
  end

  def test_dates_and_pre_epoch_instants_are_utc_even_with_a_different_database_timezone
    record = DateHistogramValue.create!(name: 'Historic observation', code: '00000000-0000-0000-0000-000000000098',
      recorded_on: Date.new(1969, 12, 31), recorded_at: Time.utc(1969, 12, 31, 23, 59, 59), price: 0)
    DateHistogramValue.with_connection { |connection| connection.execute("SET LOCAL TIME ZONE 'America/New_York'") }
    scope = DateHistogramValue.where(id: record.id)
    dates = histogram(scope: scope, field: :recorded_on, calendar_interval: :day).fetch('buckets')
    instants = histogram(scope: scope, calendar_interval: :day).fetch('buckets')

    assert_equal [{ 'key' => -86_400_000, 'key_as_string' => '1969-12-31T00:00:00.000Z', 'doc_count' => 1 }], dates
    assert_equal dates, instants
    assert_empty histogram(scope: DateHistogramValue.none, calendar_interval: :month).fetch('buckets')
  end

  def test_keyed_output_count_thresholds_and_ordering
    keyed = histogram(calendar_interval: :month, keyed: true, min_doc_count: 2).fetch('buckets')

    assert_equal ['2024-02-01T00:00:00.000Z'], keyed.keys
    assert_equal 2, keyed.values.first.fetch('doc_count')
    assert_equal Time.utc(2024, 2, 1).to_i * 1_000, keyed.values.first.fetch('key')
    ordered = histogram(calendar_interval: :month, order: { _count: :desc }).fetch('buckets')
    assert_equal([2, 1, 4, 3], ordered.map { |bucket| Time.at(bucket.fetch('key') / 1_000).utc.month })
    descending = histogram(calendar_interval: :quarter, order: { _key: :desc }).fetch('buckets')
    assert_equal([1, 3], descending.map { |bucket| bucket.fetch('doc_count') })
  end

  def test_filters_and_joined_rows_preserve_document_counts
    scope = @scope.joins('CROSS JOIN generate_series(1, 2) AS duplicate_rows')
    result = Tinkick::Aggregations.new(DateHistogramValue, scope.limit(1)).call(events: {
      date_histogram: { field: :recorded_at, calendar_interval: :month }, where: { recorded_on: { gte: Date.new(2024, 2, 1) } },
    }).fetch('events')

    assert_equal([2, 0, 1], result.fetch('buckets').map { |bucket| bucket.fetch('doc_count') })
    assert_equal 3, result.fetch('doc_count')
    refute scope.loaded?
  end

  def test_date_histogram_validates_units_options_and_column_types
    [{}, { calendar_interval: '2d' }, { calendar_interval: 'month); SELECT 1' }, { calendar_interval: :day, min_doc_count: -1 },
      { calendar_interval: :day, keyed: 'true' }, { calendar_interval: :day, order: { date: :asc } }].each do |options|
      assert_raises(ArgumentError) { histogram(**options) }
    end
    assert_raises(Tinkick::InvalidQueryError) { histogram(field: :price, calendar_interval: :day) }
    assert_raises(Tinkick::MissingFieldError) { histogram(field: :missing, calendar_interval: :day) }
    assert_raises(ArgumentError) { Tinkick::Aggregations.new(DateHistogramValue, @scope).call(events: { date_histogram: { field: :recorded_at, calendar_interval: :month }, min_doc_count: 1 }) }
    assert_raises(ArgumentError) { Tinkick::Aggregations.new(DateHistogramValue, @scope).call(events: { date_histogram: { field: :recorded_at, calendar_interval: :month }, ranges: [{}] }) }
  end

  private

  def histogram(scope: @scope, **options)
    Tinkick::Aggregations.new(DateHistogramValue, scope).call(events: { date_histogram: { field: :recorded_at }.merge(options) }).fetch('events')
  end
end
