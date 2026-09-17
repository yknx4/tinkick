# frozen_string_literal: true

require_relative "../integration_helper"

class InstrumentationTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
  end

  class InvalidProduct < Product
    default_scope { where("tinkick_instrumentation_missing_column = 1") }
  end

  def test_search_emits_one_tinkick_event_for_the_cached_page
    search = Product.search("apple", misspellings: false, countless: true, limit: 1)
    events = capture_events do
      assert_equal ["Red Apple"], search.map(&:name)
      assert_equal tinkick_test_products(:red_apple).id.to_s, search.hits.first.fetch("_id")
      assert_kind_of Integer, search.took
      refute search.has_next_page?
    end

    assert_equal ["search.tinkick"], events.map(&:name)
    assert_equal "#{Product.name} Search", events.first.payload.fetch(:name)
    assert_equal Product.name, events.first.payload.fetch(:model)
    assert_operator events.first.duration, :>, 0
  end

  def test_raw_and_projected_pages_have_the_same_event_contract
    [nil, :name].each do |projection|
      search = Product.search("apple", misspellings: false, load: false, select: projection)
      events = capture_events { assert_equal ["Red Apple"], search.map(&:name) }

      assert_equal ["search.tinkick"], events.map(&:name)
      assert_equal Product.name, events.first.payload.fetch(:model)
    end
  end

  def test_failed_queries_emit_the_exception_without_claiming_success
    query = Tinkick::Query.new(InvalidProduct, "*", fields: [:name])
    events = capture_events do
      Product.transaction(requires_new: true) do
        assert_raises(ActiveRecord::StatementInvalid) { query.records }
        raise ActiveRecord::Rollback
      end
    end

    assert_equal ["search.tinkick"], events.map(&:name)
    assert_kind_of ActiveRecord::StatementInvalid, events.first.payload.fetch(:exception_object)
    assert_nil query.took
  end

  def test_lazy_relations_emit_nothing_and_searchkick_subscribers_are_independent
    other_events = []
    callback = ->(event) { other_events << event }
    ActiveSupport::Notifications.subscribed(callback, /\.searchkick\z/) do
      events = capture_events { Product.search("apple", misspellings: false) }
      assert_empty events
      capture_events { Product.search("apple", misspellings: false).to_a }
    end
    assert_empty other_events
  end

  private

  def capture_events
    events = []
    callback = ->(event) { events << event }
    ActiveSupport::Notifications.subscribed(callback, /\.tinkick\z/) { yield }
    events
  end
end
