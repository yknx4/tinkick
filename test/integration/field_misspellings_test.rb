# frozen_string_literal: true

require_relative "../integration_helper"

class FieldMisspellingsTest < TinkickIntegrationTest
  def test_only_enabled_fields_accept_typos_while_other_fields_keep_exact_matches
    first, second = contrasting_fields("Rivendell", "Letters from Rivendell")

    assert_equal([first.id], search("rivendxll", fuzzy_fields: [:name]).map(&:id))
    assert_equal([second.id], search("rivendxll", fuzzy_fields: ["description"]).map(&:id))
    assert_equal([first.id, second.id].sort, search("rivendxll", fuzzy_fields: [:name, :description]).map(&:id).sort)
    assert_equal([first.id, second.id].sort, search("rivendell", fuzzy_fields: [:name]).map(&:id).sort)
    assert_equal([first.id, second.id].sort, search("rivendxll letters", fuzzy_fields: [:name], operator: :or).map(&:id).sort)
    assert_empty(search("rivendxll letters", fuzzy_fields: [:name], operator: :and))
  end

  def test_an_empty_field_list_disables_typos_and_fluent_options_preserve_the_source
    first, second = contrasting_fields("Rivendell", "Letters from Rivendell")
    exact = search("rivendxll", fuzzy_fields: [])
    fuzzy = exact.misspellings(fields: [:name])

    assert_empty(exact)
    assert_equal([first.id], fuzzy.map(&:id))
    assert_equal([first.id, second.id].sort, search("rivendell", fuzzy_fields: []).map(&:id).sort)
  end

  def test_two_edit_word_matching_applies_distance_prefix_and_transpositions_only_to_enabled_fields
    first, second = contrasting_fields("abcdefghij", "Notes about abcdefghij")

    assert_equal([first.id], search("abxxefghij", fuzzy_fields: [:name], edit_distance: 2).map(&:id))
    assert_equal([second.id], search("abxxefghij", fuzzy_fields: [:description], edit_distance: 2).map(&:id))
    assert_raises(Tinkick::NotImplementedError) { search("abxxefghij", fuzzy_fields: [:name], edit_distance: 2, transpositions: true).to_a }
    assert_empty(search("abxxefghij", fuzzy_fields: [:name], edit_distance: 2, prefix_length: 3))
  end

  def test_two_edit_partial_modes_route_enabled_and_disabled_fields_independently
    { word_start: "abcdefghijtail", word_middle: "leadabcdefghijtail", word_end: "leadabcdefghij" }.each do |mode, value|
      first, second = contrasting_fields(value, "Notes #{value}")
      fields = [{ name: mode }, { description: mode }]

      assert_raises(Tinkick::NotImplementedError) { search("abxxefghij", fields: fields, fuzzy_fields: [:name], edit_distance: 2).to_a }
      assert_raises(Tinkick::NotImplementedError) { search("abxxefghij", fields: fields, fuzzy_fields: [:description], edit_distance: 2).to_a }
      assert_empty(search("abxxefghij", fields: fields, fuzzy_fields: [], edit_distance: 2))
      assert_equal([first.id, second.id].sort, search("abcdefghij", fields: fields, fuzzy_fields: [], edit_distance: 2).map(&:id).sort)
    end
  end

  def test_sql_text_modes_and_native_fields_receive_their_own_fuzzy_settings
    { text_start: "Rivendell travel", text_middle: "Visit Rivendell today", text_end: "Visit Rivendell" }.each do |mode, value|
      first, second = contrasting_fields(value, "Letters from Rivendell")
      fields = [{ name: mode }, :description]

      assert_raises(Tinkick::NotImplementedError) { search("rivendxll", fields: fields, fuzzy_fields: [:name]).to_a }
      assert_equal([second.id], search("rivendxll", fields: fields, fuzzy_fields: [:description]).map(&:id))
    end
    first, second = contrasting_fields("abcdefghij travel", "Notes about abcdefghij")
    fields = [{ name: :text_start }, :description]
    assert_raises(Tinkick::NotImplementedError) { search("abxxefghij", fields: fields, fuzzy_fields: [:name], edit_distance: 2).to_a }
    assert_equal([second.id], search("abxxefghij", fields: fields, fuzzy_fields: [:description], edit_distance: 2).map(&:id))
  end

  def test_exact_phrase_and_exclusion_matching_remain_nonfuzzy
    first, second = contrasting_fields("Rivendell", "Letters from Rivendell")
    [:exact, :phrase].each do |mode|
      fields = [{ name: mode }, :description]
      assert_empty(search("rivendxll", fields: fields, fuzzy_fields: [:name]))
      assert_equal([second.id], search("rivendxll", fields: fields, fuzzy_fields: [:description]).map(&:id))
    end
    assert_empty(search("rivendxll", fuzzy_fields: [:name], exclude: "rivendell"))
    assert_equal([first.id], search("rivendxll", fuzzy_fields: [:name], exclude: "rivendxll").map(&:id))
  end

  def test_json_path_names_filters_and_counts_use_the_same_field_selection
    first = tinkick_test_products(:red_apple)
    second = tinkick_test_products(:green_pear)
    first.update!(metadata: { title: "Rivendell archives" })
    second.update!(name: "Rivendell letters", metadata: { title: "Remote village" })
    result = search("rivendxll", fields: [:name, "metadata.title"], fuzzy_fields: ["metadata.title"], where: { id: first.id })

    assert_equal([first.id], result.map(&:id))
    assert_equal(1, result.total_count)
    assert_equal([second.id], search("rivendxll", fields: [:name, "metadata.title"], fuzzy_fields: [:name]).map(&:id))
  end

  def test_field_lists_must_be_valid_subsets_of_selected_fields
    error = assert_raises(ArgumentError) { search("apple", fields: [:name], fuzzy_fields: [:description]).to_a }
    assert_includes(error.message, "specified in fields")
    [nil, "name", [123], [{}]].each do |value|
      error = assert_raises(ArgumentError) { search("apple", fuzzy_fields: value).to_a }
      assert_includes(error.message, "misspellings")
      assert_includes(error.message, "fields")
    end
  end

  private

  def contrasting_fields(name, description)
    first = tinkick_test_products(:red_apple)
    second = tinkick_test_products(:green_pear)
    first.update!(name: name, description: "Unrelated winter orchard")
    second.update!(name: "Distant coastline", description: description)
    [first, second]
  end

  def search(term, fuzzy_fields:, edit_distance: 1, transpositions: false, prefix_length: 0, **options)
    @model ||= Class.new(SearchProduct) { tinkick searchable: [:name, :description] }
    @model.search(term, fields: [:name, :description],
      misspellings: { fields: fuzzy_fields, edit_distance: edit_distance, transpositions: transpositions, prefix_length: prefix_length }, **options)
  end
end
