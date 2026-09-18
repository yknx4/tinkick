# frozen_string_literal: true

# Executable custom catalog search recipes, not gem APIs.
module CatalogSql
  module_function

  def rank(relation, exact_title: nil, metadata_only: false)
    Tinkick.warn(CatalogEntry, "Catalog SQL ranking can score and sort every matching row; inspect EXPLAIN ANALYZE before rollout.")
    weights = { has_verified_identifier: 50, has_image: 30, has_creator: 15 }
    weights[:has_extended_metadata] = 5 unless metadata_only
    factors = weights.map do |field, weight|
      "CASE WHEN #{field} THEN #{exact_title ? weight / 10.0 : weight} ELSE #{exact_title ? 0 : 1} END"
    end
    expression = if exact_title
      bonus = CatalogEntry.sanitize_sql_array(["CASE WHEN normalized_title = ? THEN 1000 ELSE 0 END", exact_title])
      "_tinkick_score * LEAST(10, #{factors.join(' + ')} + LOG(1 + popularity * 0.01)) + #{bonus}"
    else
      "_tinkick_score * #{factors.join(' * ')} * LN(2 + popularity * 100.0)"
    end
    CatalogEntry.unscoped.with(catalog_matches: relation.except(:order))
      .from("catalog_matches AS tinkick_test_catalog_entries")
      .reselect(*columns, Arel.sql("#{expression} AS _tinkick_score"))
      .order(Arel.sql("_tinkick_score DESC, id ASC"))
  end

  def columns
    CatalogEntry.column_names.map { |name| "tinkick_test_catalog_entries.#{CatalogEntry.connection.quote_column_name(name)}" }
  end
end
