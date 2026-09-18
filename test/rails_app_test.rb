# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "test_helper"
require_relative "dummy/config/environment"
require_relative "integration_helper"
require "rails/test_help"

class RailsAppTest < ActionDispatch::IntegrationTest
  self.fixture_paths = [File.expand_path("dummy/test/fixtures", __dir__)]
  self.use_transactional_tests = true
  set_fixture_class(tinkick_test_characters: TolkienCharacter)
  fixtures :tinkick_test_characters

  def test_search_page_renders_real_faker_characters
    character = tinkick_test_characters(:character_0)

    get "/characters", params: { q: character.name }

    assert_response :success
    assert_select "h1", "Search Middle-earth"
    assert_select "li[data-character-id='#{character.id}']" do
      assert_select "strong", character.name
    end
    assert_select "input[name=q][value=?]", character.name
  end

  def test_json_search_executes_a_tin_query_and_returns_the_stored_record
    character = tinkick_test_characters(:character_0)
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get "/characters.json", params: { q: character.name }
    end

    assert_response :success
    row = response.parsed_body.fetch("characters").find { |entry| entry.fetch("id") == character.id }
    assert_equal character.name, row.fetch("name")
    assert_equal character.location, row.fetch("location")
    assert statements.any? { |sql| sql.include?("==>") && sql.include?("tin.score(") }
  end

  def test_filters_and_page_limits_apply_through_the_controller
    race = tinkick_test_characters(:character_0).race

    get "/characters.json", params: { q: "*", race: race }

    assert_response :success
    rows = response.parsed_body.fetch("characters")
    assert rows.any?
    assert_operator rows.length, :<=, 10
    assert rows.all? { |entry| entry.fetch("race") == race }
  end

  def test_match_all_returns_only_the_requested_page_from_the_full_dataset
    get "/characters.json", params: { q: "*" }

    assert_response :success
    assert_equal 64, TolkienCharacter.count
    assert_equal 10, response.parsed_body.fetch("characters").length
  end

  def test_poem_text_matches_without_appearing_in_character_names
    poem = tinkick_test_characters(:character_0).poem
    expected_ids = TolkienCharacter.where(poem: poem).order(:id).ids

    get "/characters.json", params: { q: poem }

    assert_response :success
    assert_equal expected_ids, response.parsed_body.fetch("characters").map { |entry| entry.fetch("id") }.sort
    refute TolkienCharacter.where(name: poem).exists?
  end

  def test_native_one_edit_typo_matching_without_transposition_emulation
    character = tinkick_test_characters(:character_0)
    assert_equal "Hunleth", character.name

    get "/characters.json", params: { q: "Hunlet" }

    assert_response :success
    assert_equal ["Hunleth"], response.parsed_body.fetch("characters").map { |entry| entry.fetch("name") }

    get "/characters.json", params: { q: "Hnuleth" }

    assert_response :success
    assert_empty response.parsed_body.fetch("characters")
  end

  def test_countless_metadata_does_not_issue_a_count_query
    statements = capture_queries { get "/characters.json", params: { q: "*" } }

    assert_response :success
    assert_equal true, response.parsed_body.fetch("has_next_page")
    assert_equal 2, response.parsed_body.fetch("next_page")
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
  end

  def test_cursor_requests_traverse_the_entire_dataset_without_offsets_or_counts
    expected_ids = TolkienCharacter.order(:id).ids
    ids = []
    cursor = nil
    statements = capture_queries do
      7.times do
        get "/characters.json", params: { q: "*", pagination: "keyset", after: cursor }
        assert_response :success
        data = response.parsed_body
        ids.concat(data.fetch("characters").map { |row| row.fetch("id") })
        cursor = data.fetch("next_cursor")
      end
    end

    assert_equal expected_ids, ids
    assert_nil cursor
    assert_equal false, response.parsed_body.fetch("has_next_page")
    refute statements.any? { |sql| sql.match?(/\bOFFSET\b|COUNT\(/i) }
  end

  def test_invalid_cursor_returns_a_clear_bad_request
    get "/characters.json", params: { pagination: "keyset", after: "not-a-valid-cursor" }

    assert_response :bad_request
    assert_match(/keyset cursor/, response.body)
  end

  def test_empty_results_and_query_injection_are_handled_as_search_text
    ["unfindablezzzzcharacter", "' OR 1=1 -- unfindablezzzzcharacter"].each do |term|
      get "/characters.json", params: { q: term }

      assert_response :success
      assert_empty response.parsed_body.fetch("characters")
    end
  end

  def test_database_writes_are_searchable_on_the_next_request_without_reindexing
    character = tinkick_test_characters(:character_0)
    character.update!(name: "ImmediateVisibilityCharacter")

    get "/characters.json", params: { q: "ImmediateVisibilityCharacter" }

    assert_response :success
    assert_equal [character.id], response.parsed_body.fetch("characters").map { |entry| entry.fetch("id") }
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
