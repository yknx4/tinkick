# frozen_string_literal: true

require_relative "support/catalog_helper"

class CatalogTimeoutTest < CatalogIntegrationTest
  # The router can reject savepoint rollback after cancellation; test a real
  # top-level transaction, matching the documented application recipe.
  self.use_transactional_tests = false

  def test_statement_timeout_cancels_search_and_transaction_restores_connection
    connection = CatalogEntry.connection
    previous = connection.select_value("SHOW statement_timeout")
    relation = search("Hobbit", block: ->(query) { query.joins("CROSS JOIN (SELECT pg_sleep(1)) AS delay") }).to_relation
    error = assert_raises(ActiveRecord::QueryCanceled) do
      CatalogEntry.transaction do
        connection.execute("SET LOCAL statement_timeout = '100ms'")
        relation.to_a
      end
    end
    assert_equal "57014", error.cause.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
    assert_equal previous, connection.select_value("SHOW statement_timeout")
    assert_includes search("Hobbit").map(&:id), entry(:hobbit).id
  end
end
