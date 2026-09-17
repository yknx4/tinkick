# frozen_string_literal: true

require_relative "../integration_helper"

class EnumKeysetTest < TinkickIntegrationTest
  setup do
    @model = Class.new(ActiveRecord::Base) do
      self.table_name = "tinkick_test_cursor_values"
      enum :status, { published: 0, draft: 1 }
      tinkick searchable: [:name]
    end
    attributes = { recorded_on: "2026-09-17", recorded_at: "2026-09-17T12:00:00.123456Z", price: "1.25" }
    @first = @model.create!(**attributes, name: "Apple", code: "00000000-0000-0000-0000-000000000001", status: :published)
    @second = @model.create!(**attributes, name: "Banana", code: "00000000-0000-0000-0000-000000000002", status: :draft)
  end

  def test_integer_enums_encode_physical_values_and_compare_physical_sql_values
    keyset = Tinkick::Keyset.new(@model, :status)
    cursor = keyset.encode(@first.attributes)

    assert_equal [0, @first.id], JSON.parse(Base64.urlsafe_decode64(cursor)).fetch("values")
    assert_equal [@second.id], keyset.apply(@model.all, cursor).ids
    assert_empty keyset.apply(@model.all, keyset.encode(@second.attributes))

    descending = Tinkick::Keyset.new(@model, { status: :desc })
    assert_equal [@first.id], descending.apply(@model.all, descending.encode(@second.attributes)).ids
  end

  def test_enum_keysets_work_with_model_raw_projected_and_scoped_results
    options = [
      {},
      { load: false },
      { load: false, select: :name },
      { scope_results: ->(records) { records.where(status: :draft) } },
    ]
    options.each do |settings|
      first = @model.search("*", order: :status, keyset: true, limit: 1, **settings)
      assert_equal(settings[:scope_results] ? [] : [@first.id], first.map(&:id))
      assert first.has_next_page?
      refute first.out_of_range?
      cursor = first.next_cursor
      assert_equal [0, @first.id], JSON.parse(Base64.urlsafe_decode64(cursor)).fetch("values")
      if settings[:select]
        assert_equal %w[id name], first.first.to_h.keys.sort
      elsif !settings[:scope_results]
        assert_equal "published", first.first.status
      end

      second = @model.search("*", order: :status, keyset: true, limit: 1, after: cursor, **settings)
      assert_equal [@second.id], second.map(&:id)
      assert_equal "draft", second.first.status unless settings[:select]
      refute second.has_next_page?
      assert_nil second.next_cursor
    end
  end
end
