# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/keyset"

class KeysetTest < TinkickIntegrationTest
  class CursorValue < ActiveRecord::Base
    self.table_name = "tinkick_test_cursor_values"
  end

  setup do
    @first = CursorValue.create!(name: "Apple", code: "00000000-0000-0000-0000-000000000001",
      recorded_on: "2026-09-16", recorded_at: "2026-09-17T12:00:00.123456Z", price: "12345678901234567890.1234567890")
    @second = CursorValue.create!(name: "Banana", code: "00000000-0000-0000-0000-000000000002",
      recorded_on: "2026-09-17", recorded_at: "2026-09-17T12:00:00.123457Z", price: "12345678901234567890.1234567891")
  end

  test "column cursors round trip UUID date timestamp and decimal values without precision loss" do
    [:code, :recorded_on, :recorded_at, :price].each do |field|
      keyset = Tinkick::Keyset.new(CursorValue, field)
      ordered = CursorValue.order(Arel.sql(keyset.order_sql))
      first = ordered.first
      second = keyset.apply(ordered, keyset.encode(first.attributes)).first

      assert_equal @first.id, first.id, field.to_s
      assert_equal @second.id, second.id, field.to_s
      assert_equal [@first[field], @second[field]], ordered.pluck(field), field.to_s
      refute_equal first[field], second[field], field.to_s
      assert_empty keyset.apply(ordered, keyset.encode(second.attributes))

      descending = Tinkick::Keyset.new(CursorValue, { field => :desc })
      reverse_order = CursorValue.order(Arel.sql(descending.order_sql))
      assert_equal @second.id, reverse_order.first.id, field.to_s
      assert_equal [@first.id], descending.apply(reverse_order, descending.encode(@second.attributes)).ids, field.to_s
    end
  end

  test "invalid typed cursor values fail before SQL execution" do
    { code: "not-a-uuid", recorded_on: "2026-99-99", recorded_at: "tomorrow", price: "Infinity", id: 10**100 }.each do |field, value|
      keyset = Tinkick::Keyset.new(CursorValue, field)
      payload = JSON.parse(Base64.urlsafe_decode64(keyset.encode(@first.attributes)))
      payload.fetch("values")[0] = value
      cursor = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
      statements = []
      callback = ->(_name, _start, _finish, _id, event) { statements << event[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        assert_raises(Tinkick::InvalidQueryError, field.to_s) { keyset.apply(CursorValue.all, cursor) }
      end
      assert_empty statements
    end
  end

  test "date cursors reject ISO forms that Active Record cannot cast" do
    keyset = Tinkick::Keyset.new(CursorValue, :recorded_on)
    payload = JSON.parse(Base64.urlsafe_decode64(keyset.encode(@first.attributes)))

    ["2026-260", "2026-W38-4"].each do |date|
      payload.fetch("values")[0] = date
      cursor = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
      error = assert_raises(Tinkick::InvalidQueryError) { keyset.apply(CursorValue.all, cursor) }
      assert_includes error.message, "recorded_on"
    end
  end

  test "floating point and array order columns are rejected explicitly" do
    [:ratio, :tags].each do |field|
      error = assert_raises(Tinkick::InvalidQueryError) { Tinkick::Keyset.new(CursorValue, field) }
      assert_includes error.message, "scalar"
    end
  end
end
