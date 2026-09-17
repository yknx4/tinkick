# frozen_string_literal: true

require_relative "../integration_helper"

class EnumLabelFilterValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
  enum :status, { published: 0, draft: 30, archived: 60, "éclair" => 90 }
end

class EnumPatternFilterProduct < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
  enum :description, { "100%_\\ready" => "R", live: "R", "draft'); DROP TABLE nope; --" => "D", absent: nil },
    scopes: false, instance_methods: false
end

class EnumLabelFilterTest < TinkickIntegrationTest
  setup do
    attributes = { recorded_on: "2026-09-17", recorded_at: "2026-09-17T12:00:00Z", price: "1.25",
      code: "00000000-0000-0000-0000-000000000001" }
    @records = %w[published draft archived éclair].map do |label|
      EnumLabelFilterValue.create!(**attributes, name: "#{label} beacon", status: label)
    end
    unknown = EnumLabelFilterValue.create!(**attributes, name: "unknown beacon", status: :draft)
    EnumLabelFilterValue.where(id: unknown.id).update_all(status: 999)
    @scope = EnumLabelFilterValue.where(id: [*@records.map(&:id), unknown.id])
  end

  def test_comparisons_and_ranges_use_keyword_label_order
    assert_equal %w[draft published], labels(status: { gte: "draft", lte: "published" })
    assert_equal ["published"], labels(status: { gt: "draft", lt: "éclair" })
    assert_equal %w[draft published], labels(status: "draft".."published")
    assert_equal ["draft"], labels(status: "draft"..."published")
    assert_equal ["archived"], labels(status: ..."draft")
    assert_equal %w[published éclair], labels(status: "published"..)
    assert_equal %w[draft published éclair], labels(status: { gt: "archived" })
  end

  def test_numeric_bounds_are_keyword_strings_and_missing_labels_are_excluded
    assert_equal %w[archived draft published éclair], labels(status: { gt: 0 })
    assert_empty labels(status: { lt: 1 })
    assert_empty labels(status: { gte: "z", lt: "é" })
    assert_equal %w[archived draft published éclair], labels(status: /\A.*\z/)
  end

  def test_prefix_like_ilike_and_regexp_match_labels
    assert_equal ["published"], labels(status: { prefix: "publ" })
    assert_equal ["draft"], labels(status: { like: "%raft" })
    assert_equal ["published"], labels(status: { ilike: "PUBL%" })
    assert_equal %w[archived published], labels(status: /\A(archived|published)\z/)
    assert_equal ["published beacon"], Tinkick::Relation.new(EnumLabelFilterValue, "beacon", fields: [:name],
      misspellings: false, where: { status: { prefix: "publ" } }).map(&:name)
  end

  def test_patterns_use_canonical_labels_and_bind_punctuation_and_null_backings
    ready = EnumPatternFilterProduct.create!(name: "Ready pattern", description: "100%_\\ready")
    quoted = EnumPatternFilterProduct.create!(name: "Quoted pattern", description: "draft'); DROP TABLE nope; --")
    absent = EnumPatternFilterProduct.create!(name: "Absent pattern", description: :absent)
    unknown = SearchProduct.create!(name: "Unknown pattern", description: "REMOVED")
    scope = EnumPatternFilterProduct.where(id: [ready.id, quoted.id, absent.id, unknown.id])
    filter = Tinkick::Filter.new(EnumPatternFilterProduct)

    assert_equal [ready.id], filter.apply(scope, description: { like: "100\\%\\_\\ready" }).ids
    assert_equal [quoted.id], filter.apply(scope, description: { prefix: "draft'); DROP TABLE" }).ids
    assert_equal [absent.id], filter.apply(scope, description: /\Aabsent\z/).ids
    assert_empty filter.apply(scope, description: /live/)
    assert_equal [ready.id, quoted.id, absent.id].sort, filter.apply(scope, description: /\A.*\z/).ids.sort
    assert_equal [quoted.id], filter.apply(scope, description: { gt: "b", lt: "e" }).ids
  end

  def test_only_label_expression_filters_warn_about_the_scan_cost
    original_logger = EnumLabelFilterValue.logger
    output = StringIO.new
    EnumLabelFilterValue.logger = Logger.new(output, level: Logger::WARN)

    labels(status: :draft)
    assert_empty output.string
    labels(status: { prefix: "dra" })
    assert_includes output.string, "enum labels"
    assert_includes output.string, "CASE"
    output.truncate(0)
    output.rewind
    labels(status: "draft".."published")
    assert_includes output.string, "enum labels"
  ensure
    EnumLabelFilterValue.logger = original_logger
  end

  private

  def labels(conditions)
    Tinkick::Filter.new(EnumLabelFilterValue).apply(@scope, conditions).pluck(:status).sort
  end
end
