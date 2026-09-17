# frozen_string_literal: true

require_relative "../integration_helper"

class DatabaseTest < TinkickIntegrationTest
  def test_fixtures_are_searchable_with_real_tin
    count = SearchProduct.connection.select_value(<<~SQL)
      SELECT count(*) FROM tinkick_test_products WHERE name ==> 'apple'
    SQL

    assert_equal(1, count)
  end

  def test_tin_observes_writes_and_rollback
    SearchProduct.transaction(requires_new: true) do
      SearchProduct.create!(name: "Orange", description: "Citrus")

      assert_equal(1, SearchProduct.where("name ==> ?", "orange").count)

      raise ActiveRecord::Rollback
    end

    assert_equal(0, SearchProduct.where("name ==> ?", "orange").count)
  end
end
