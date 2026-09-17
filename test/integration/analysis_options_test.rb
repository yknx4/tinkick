# frozen_string_literal: true

require_relative "../integration_helper"

class AnalysisOptionsTest < TinkickIntegrationTest
  class ConfigureNameIndex < ActiveRecord::Migration[8.0]
    def initialize(case_folding:, accent_folding:)
      super()
      @case_folding = case_folding
      @accent_folding = accent_folding
    end

    def up
      remove_index :tinkick_test_products, :name, using: :tin
      execute <<~SQL
        CREATE INDEX index_tinkick_test_products_on_name ON tinkick_test_products USING tin (name)
        WITH (case_folding = #{connection.quote(@case_folding)}, accent_folding = #{connection.quote(@accent_folding)})
      SQL
    end
  end

  class RemoveUnaccent < ActiveRecord::Migration[8.0]
    def up
      raise "Expected tinkick_test" unless connection.select_value("SELECT current_database()") == "tinkick_test"

      execute "DROP EXTENSION unaccent RESTRICT"
    end
  end

  setup do
    @previous = Tinkick.model_options
    Tinkick.model_options = {}
    @first = tinkick_test_products(:red_apple)
    @second = tinkick_test_products(:green_pear)
    @first.update!(name: "Jalapeño")
    @second.update!(name: "jalapeno")
  end

  teardown do
    Tinkick.model_options = @previous
    SearchProduct.reset_column_information
  end

  def test_declarations_store_explicit_values_without_connecting
    statements = []
    listener = ->(*arguments) { statements << arguments.last.fetch(:sql) }
    model = nil
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      model = build_model(case_sensitive: true, special_characters: false)
    end

    assert_empty statements
    assert_equal true, model.tinkick_options.fetch(:case_sensitive)
    assert_equal false, model.tinkick_options.fetch(:special_characters)
  end

  def test_case_sensitive_native_search_requires_a_matching_migrated_index
    model = build_model(case_sensitive: true)
    error = assert_raises(Tinkick::Error) { ids(model, "Jalapeño") }

    assert_includes error.message, "case_folding"
    assert_includes error.message, "preserve"
    assert_match(/Rails migration/, error.message)
    configure_index(case_folding: "preserve", accent_folding: "fold")
    assert_equal [@first.id], ids(model, "Jalapeno")
    assert_equal [@second.id], ids(model, "jalapeno")
  end

  def test_accent_sensitive_native_search_requires_a_matching_migrated_index
    model = build_model(special_characters: false)
    error = assert_raises(Tinkick::Error) { ids(model, "Jalapeño") }

    assert_includes error.message, "accent_folding"
    assert_includes error.message, "preserve"
    configure_index(case_folding: "fold", accent_folding: "preserve")
    assert_equal [@first.id], ids(model, "JALAPEÑO")
    assert_equal [@second.id], ids(model, "jalapeno")
  end

  def test_omitted_options_adopt_custom_analysis_but_explicit_nil_requests_fold_defaults
    configure_index(case_folding: "preserve", accent_folding: "preserve")
    model = build_model

    refute model.tinkick_options.key?(:case_sensitive)
    refute model.tinkick_options.key?(:special_characters)
    assert_equal [@first.id], ids(model, "Jalapeño")
    assert_empty ids(model, "jalapeño")
    [:case_sensitive, :special_characters].each do |option|
      explicit = build_model(**{ option => nil })
      error = assert_raises(Tinkick::Error) { ids(explicit, "Jalapeño") }
      assert_includes error.message, "fold"
    end
  end

  def test_explicit_fold_settings_and_nil_use_default_index_analysis
    [{ case_sensitive: false, special_characters: true }, { case_sensitive: nil, special_characters: nil }].each do |options|
      assert_equal [@first.id, @second.id].sort, ids(build_model(**options), "JALAPENO").sort
    end
  end

  def test_declaring_one_analysis_option_does_not_override_the_other_index_policy
    configure_index(case_folding: "preserve", accent_folding: "preserve")

    [build_model(case_sensitive: true), build_model(special_characters: false)].each do |model|
      assert_equal [@first.id], ids(model, "Jalapeño")
      assert_empty ids(model, "jalapeño")
      assert_empty ids(model, "Jalapeno")
    end
  end

  def test_global_defaults_and_explicit_nil_overrides_preserve_key_presence
    Tinkick.model_options = { case_sensitive: true, special_characters: false }
    inherited = build_model
    overridden = build_model(case_sensitive: nil, special_characters: nil)

    assert_equal true, inherited.tinkick_options.fetch(:case_sensitive)
    assert_equal false, inherited.tinkick_options.fetch(:special_characters)
    assert_nil overridden.tinkick_options.fetch(:case_sensitive)
    assert_nil overridden.tinkick_options.fetch(:special_characters)
    assert_equal [@first.id, @second.id].sort, ids(overridden, "JALAPENO").sort
    assert_raises(Tinkick::Error) { ids(inherited, "Jalapeño") }
  end

  def test_whole_field_modes_apply_case_and_accent_controls_independently
    @first.update!(name: "JALAPEÑO")
    @second.update!(name: "unrelated")
    [:text_start, :text_middle, :text_end].each do |mode|
      [true, false].product([true, false]).each do |case_sensitive, special_characters|
        model = build_model(match: mode, case_sensitive: case_sensitive, special_characters: special_characters)
        assert_equal [@first.id], ids(model, "JALAPEÑO")
        assert_equal(case_sensitive ? [] : [@first.id], ids(model, "jalapeño"))
        assert_equal(special_characters ? [@first.id] : [], ids(model, "JALAPENO"))
        assert_equal(!case_sensitive && special_characters ? [@first.id] : [], ids(model, "jalapeno"))
      end
    end
  end

  def test_accent_preserving_sql_does_not_require_unaccent
    # RESTRICT refuses unexpected dependencies; the fixture transaction restores it.
    capture_io { RemoveUnaccent.new.migrate(:up) }
    refute SearchProduct.connection.extension_enabled?("unaccent")
    model = build_model(match: :text_start, special_characters: false)

    assert_equal [@first.id], ids(model, "JALAPEÑO")
    assert_equal [@second.id], ids(model, "JALAPENO")
    assert_raises(Tinkick::Error) { ids(build_model(match: :text_start), "Jalapeño") }
  end

  def test_case_sensitive_sql_casts_citext_before_like_and_regex_matching
    # CITEXT is installed by a committed test migration: the router cannot
    # resolve a type created inside this fixture transaction when preparing SQL.
    model = build_model(case_sensitive: true, special_characters: false)
    matcher = Tinkick::TextMatch.new(model)
    @first.update!(name: "JALAPEÑO")
    @second.update!(name: "unrelated")

    [false, true, { edit_distance: 2 }].each do |misspellings|
      sql, binds = matcher.predicate('"name"::citext', "JALAPEÑO", match: :text_start, misspellings: misspellings)
      assert_equal [@first.id], model.where(Arel.sql(sql, *binds)).pluck(:id)
      sql, binds = matcher.predicate('"name"::citext', "jalapeño", match: :text_start, misspellings: misspellings)
      assert_empty model.where(Arel.sql(sql, *binds)).pluck(:id)
    end
  end

  def test_json_text_highlights_and_exclusions_share_declared_normalization
    @first.update!(metadata: { title: "JALAPEÑO" })
    @second.update!(metadata: { title: "jalapeño" })
    model = build_model(searchable: ["metadata.title"], match: :text_start, case_sensitive: true, special_characters: false)
    page = model.tinkick_search("JAL", misspellings: false, highlight: true)

    assert_equal [@first.id], page.map(&:id)
    assert_equal [{ "metadata.title": "<em>JALAPEÑO</em>" }], page.highlights
    assert_equal [@first.id], ids(model, "JAL", exclude: "jal")
    assert_empty ids(model, "JAL", exclude: "JAL")
  end

  def test_fuzzy_text_uses_selected_normalization_before_fixed_prefix_and_edits
    @first.update!(name: "JALAPEÑO")
    @second.update!(name: "unrelated")
    folded = build_model(match: :text_start, case_sensitive: true, special_characters: true)
    preserved = build_model(match: :text_start, case_sensitive: true, special_characters: false)

    assert_equal [@first.id], ids(folded, "JALAPENO", misspellings: { prefix_length: 7 })
    assert_empty ids(preserved, "JALAPENO", misspellings: { prefix_length: 7 })
    assert_equal [@first.id], ids(preserved, "JALXPENO", misspellings: { edit_distance: 2 })
    assert_empty ids(preserved, "JALXPENO", misspellings: false)
  end

  def test_exact_match_keeps_its_byte_sensitive_contract_regardless_of_analysis_options
    model = build_model(match: :exact, case_sensitive: false, special_characters: true)

    assert_equal [@first.id], ids(model, "Jalapeño")
    assert_empty ids(model, "JALAPEÑO")
    assert_empty ids(model, "Jalapeno")
  end

  def test_analysis_options_reject_non_boolean_non_nil_values
    [:case_sensitive, :special_characters].each do |option|
      [0, "false", [], {}].each do |value|
        error = assert_raises(ArgumentError) { build_model(**{ option => value }) }
        assert_includes error.message, "true, false, or nil"
      end
    end
  end

  private

  def build_model(**options)
    Class.new(SearchProduct) { tinkick(searchable: [:name], **options) }
  end

  def ids(model, term, **options)
    model.tinkick_search(term, misspellings: false, **options).map(&:id)
  end

  def configure_index(**options)
    capture_io { ConfigureNameIndex.new(**options).migrate(:up) }
    SearchProduct.reset_column_information
  end
end
