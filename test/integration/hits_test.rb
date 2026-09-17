# frozen_string_literal: true

require_relative "../integration_helper"

class HitsTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
  end

  def test_hits_expose_durable_identity_and_native_scores_without_counting
    search = Product.search("apple", misspellings: false, countless: true, limit: 1)
    statements = capture_queries do
      hit = search.hits.fetch(0)
      assert_equal %w[_id _index _score], hit.keys.sort
      assert_equal tinkick_test_products(:red_apple).id.to_s, hit.fetch("_id")
      assert_equal Product.table_name, hit.fetch("_index")
      assert_operator hit.fetch("_score"), :>, 0
      assert_same search.hits, search.hits
      duration = search.took
      assert_nil search.error
      assert_equal [hit.fetch("_score")], search.with_score.map { |_record, score| score }
      assert_equal duration, search.took
    end
    assert_equal 1, page_queries(statements).length
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
  end

  def test_models_and_hits_share_the_page_in_both_access_orders
    [true, false].each do |hits_first|
      search = Product.search("*", order: :name, select: true)
      statements = capture_queries do
        hits_first ? search.hits : search.to_a
        pairs = search.with_hit.to_a
        assert_instance_of Enumerator, search.with_hit
        assert_equal search.map(&:id).map(&:to_s), pairs.map { |_record, hit| hit.fetch("_id") }
        pairs.each do |record, hit|
          assert_same record, search.find { |value| value.id == record.id }
          assert_equal record.description, hit.fetch("_source").fetch("description")
          assert_equal record.id, hit.fetch("_source").fetch("id")
        end
        yielded = []
        search.with_hit { |record, hit| yielded << [record.id.to_s, hit.fetch("_id")] }
        assert yielded.all? { |identifier, hit_id| identifier == hit_id }
      end
      assert_equal 1, page_queries(statements).length
    end
  end

  def test_hits_keep_pre_scope_page_while_with_hit_pairs_only_visible_records
    missing_id = tinkick_test_products(:green_pear).id.to_s
    [true, false].each do |hits_first|
      calls = 0
      search = Product.search("*", order: :name, select: :name, scope_results: ->(records) {
        calls += 1
        records.where(name: "Red Apple")
      })
      statements = capture_queries do
        if hits_first
          assert_equal 2, search.hits.length
          assert_equal 0, calls
        else
          search.to_a
        end
        assert_equal ["Green Pear", "Red Apple"], search.hits.map { |hit| hit.fetch("_source").fetch("name") }
        pairs = search.with_hit.to_a
        assert_equal ["Red Apple"], pairs.map { |record, _hit| record.name }
        assert_same search.hits.last, pairs.first.last
        assert_equal [{ id: missing_id, model: Product }], search.missing_records
        assert_equal 1, calls
      end
      assert_equal 1, page_queries(statements).length
      assert_equal 2, statements.count { |sql| sql.include?('FROM "tinkick_test_products"') }
    end
  end

  def test_raw_projection_hides_identity_and_cursor_columns_only_from_source
    search = Product.search("*", order: :name, keyset: true, limit: 1, load: false, select: :description)
    statements = capture_queries do
      hit = search.hits.fetch(0)
      assert_equal({ "description" => "Ripe fruit" }, hit.fetch("_source"))
      row, paired = search.with_hit.first
      assert_same hit, paired
      assert_equal %w[description id], row.to_h.keys.sort
      assert_equal row.id.to_s, hit.fetch("_id")
      assert search.has_next_page?
      refute_nil search.next_cursor
      assert_equal 1, search.hits.length
    end
    assert_equal 1, page_queries(statements).length
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
  end

  def test_source_presence_matches_load_and_selection_options
    [true, false].each do |load|
      [nil, false, true, [], [:absent], {}].each do |selection|
        hit = Product.search("*", load: load, select: selection, limit: 1).hits.fetch(0)
        omitted = selection == [] || (load && (selection.nil? || selection == false))
        assert_equal !omitted, hit.key?("_source"), "load=#{load} select=#{selection.inspect}"
        next if omitted

        source = hit.fetch("_source")
        assert_equal(selection == [:absent] ? [] : Product.column_names.sort, source.keys.sort)
        refute source.key?("_tinkick_score")
      end
    end
  end

  def test_nested_source_filter_keeps_models_complete_and_does_not_mutate_them
    tinkick_test_products(:red_apple).update!(metadata: { hero: "Arwen", home: "Rivendell", active: false })
    [true, false].each do |load|
      search = Product.search("apple", misspellings: false, load: load,
        select: { includes: ["metadata.hero", "metadata.active"] })
      hit = search.hits.fetch(0)
      assert_equal({ "metadata" => { "hero" => "Arwen", "active" => false } }, hit.fetch("_source"))
      record, paired = search.with_hit.first
      assert_same hit, paired
      assert_equal "Rivendell", record.metadata.fetch("home") if load
      assert_equal "Arwen", record.metadata.fetch("hero")
    end
  end

  def test_uuid_primary_keys_and_enums_keep_their_deserialized_values
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "tinkick_test_cursor_values"
      self.primary_key = "code"
      enum :status, { published: 0, draft: 1 }
      tinkick searchable: [:name]
    end
    identifier = "00000000-0000-0000-0000-000000000041"
    model.create!(name: "Rivendell archive", code: identifier, status: :draft,
      recorded_on: "2026-09-17", recorded_at: "2026-09-17T12:00:00Z", price: "1.25")
    [true, false].each do |load|
      search = model.search("archive", misspellings: false, load: load, select: [:status])
      hit = search.hits.fetch(0)
      assert_equal identifier, hit.fetch("_id")
      assert_equal({ "status" => "draft" }, hit.fetch("_source"))
      assert_equal identifier, search.with_hit.first.first["code"]
    end
  end

  def test_hits_do_not_run_association_preloads_and_empty_pages_pair_cleanly
    search = Product.search("*", includes: :not_an_association)
    assert_equal 2, search.hits.length
    assert_raises(ActiveRecord::AssociationNotFoundError) { search.with_hit.to_a }

    empty = Product.search("unfindablezzzz", misspellings: false)
    assert_empty empty.hits
    assert_empty empty.with_hit.to_a
  end

  def test_hit_identity_remains_paired_after_a_result_primary_key_changes
    search = Product.search("apple", misspellings: false)
    record = search.to_a.first
    identifier = record.id.to_s
    record.id = 999

    first = search.with_hit.first
    assert_same record, first.first
    assert_equal identifier, first.last.fetch("_id")
    record.id = 998
    assert_same first.last, search.with_hit.first.last
  end

  def test_hit_sources_remain_the_fetched_snapshot_after_model_or_raw_edits
    tinkick_test_products(:red_apple).update!(metadata: { hero: "Arwen" })
    [true, false].each do |load|
      search = Product.search("apple", misspellings: false, load: load, select: true)
      record = search.to_a.first
      if load
        record.update!(name: "Edited title")
      else
        record.to_h["name"] = "Edited title"
      end
      record.metadata["hero"] = "Changed locally"
      source = search.hits.fetch(0).fetch("_source")
      assert_equal "Red Apple", source.fetch("name")
      assert_equal "Arwen", source.fetch("metadata").fetch("hero")
      Product.where(id: record.id).update_all(name: "Red Apple") if load
    end
  end

  private

  def page_queries(statements)
    statements.select { |sql| sql.include?(" AS _tinkick_score") }
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
