# frozen_string_literal: true

require_relative "../integration_helper"

class RegexpFilterTest < TinkickIntegrationTest
  setup do
    SearchProduct.delete_all
    ["Moria gate", "moria\nGATE", "Rivendell 42", "Rivendell 4d", "Éowyn's map", "éowyn's map", "^Moria$", "Moria|Gondor"].each_with_index do |name, index|
      SearchProduct.create!(id: index + 1, name: name, description: "Travel archive", tags: [name], metadata: { title: name })
    end
  end

  def test_unanchored_literals_fold_ascii_without_folding_other_scripts
    assert_equal [1, 2, 7, 8], matches(/moria/i)
    assert_equal [6], matches(/éowyn/i)
    assert_equal [1, 7, 8], matches(/Moria/)
  end

  def test_absolute_anchors_and_literal_line_anchor_characters_follow_searchkick
    assert_equal [1, 8], matches(/\AMoria/)
    assert_equal [1, 2], matches(/gate\z/i)
    assert_equal [7], matches(/^Moria$/)
    assert_empty matches(/\AMoria\z/)
  end

  def test_predefined_ascii_classes_and_newlines_use_lucene_rules
    assert_equal [3], matches(/\d{2}\z/)
    assert_equal [1, 2], matches(/\Amoria\sgate\z/i)
    assert_equal [1, 2], matches(/\Amoria.gate\z/i)
    assert_equal [3, 4], matches(/\ARivendell \w{2}\z/)
  end

  def test_character_ranges_do_not_gain_literal_case_folding
    assert_equal [1, 7, 8], matches(/[A-Z]oria/i)
    assert_equal [2], matches(/[a-z]oria/i)
    assert_equal [1, 2, 7, 8], matches(/[mM]oria/i)
  end

  def test_escaped_punctuation_can_start_a_character_range
    ["$", "!", ".", "/", "0"].each_with_index do |name, index|
      SearchProduct.find(index + 1).update!(name: name)
    end

    assert_equal [1, 2, 3, 4], matches(Regexp.new("\\A[\\!-\\/]\\z"))
  end

  def test_escaped_range_start_does_not_add_a_literal_hyphen
    ["-", ".", "/", "0"].each_with_index do |name, index|
      SearchProduct.find(index + 1).update!(name: name)
    end

    assert_equal [2, 3, 4], matches(Regexp.new("\\A[\\.-0]\\z"))
  end

  def test_groups_alternatives_and_quoted_strings
    assert_equal [1, 2, 7, 8], matches(/(moria|gondor)/i)
    assert_equal [8], matches(/"Moria|Gondor"/)
    assert_equal [3, 4], matches(/\ARivendell (42|4d)\z/)
  end

  def test_array_and_json_text_values_share_the_same_pattern_semantics
    pattern = /\ARivendell \d{2}\z/

    assert_equal [3], filtered(tags: pattern).ids
    assert_equal [3], filtered("metadata.title" => pattern).ids
    assert_equal [1, 2, 4, 5, 6, 7, 8], filtered(_not: { name: pattern }).order(:id).ids
  end

  def test_pattern_values_cannot_change_the_sql_filter
    assert_empty matches(/Moria' OR TRUE --/)
    assert_empty filtered(name: /Rivendell/, description: "Missing archive")
  end

  def test_negated_classes_and_predefined_complements
    assert_equal [4], matches(/\ARivendell [^a-z]\D\z/)
    assert_equal [1, 2, 5, 6, 7, 8], matches(/\A\D+\z/)
    assert_equal [7, 8], matches(/\A\S+\z/)
    assert_equal [1, 2, 3, 4, 5, 6, 7, 8], matches(/\W/)
    assert_equal [3], matches(/[\d]{2}\z/)
  end

  def test_escaped_punctuation_and_non_bmp_characters_remain_literals
    SearchProduct.find(1).update!(name: 'map\\trail 😀')

    assert_equal [1], matches(/map\\trail 😀/)
    assert_equal [8], matches(/Moria\|Gondor/)
    assert_empty matches(/map\\trail 😃/)
  end

  def test_large_and_unbounded_repetition_limits
    SearchProduct.find(1).update!(name: "a" * 260)
    SearchProduct.find(2).update!(name: "a" * 259)

    assert_equal [1], matches(/\Aa{260}\z/)
    assert_equal [1, 2], matches(/\Aa{1,260}\z/)
    assert_equal [1, 2], matches(/\Aa{259,}\z/)
    assert_empty matches(/\Aa{0}\z/)
    assert_equal [1, 2], matches(/\A(a+)?\z/)
  end

  def test_invalid_lucene_escapes_fail_before_the_search
    error = assert_raises(Tinkick::InvalidQueryError) { matches(/\bMoria\b/) }

    assert_includes error.message, "Lucene"
    assert_includes error.message, "\\b"
  end

  def test_empty_absolute_pattern_matches_only_empty_values
    SearchProduct.find(1).update!(name: "")

    assert_equal [1], matches(/\A\z/)
    assert_equal [1], matches(/\A()\z/)
    assert_equal [1, 2, 3, 4, 5, 6, 7, 8], matches(//)
  end

  def test_public_search_composes_regex_with_native_tin_and_warns
    previous_logger = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)

    model = Class.new(SearchProduct) { tinkick searchable: [:description] }
    assert_equal [3], model.search("archive", fields: [:description], misspellings: false,
      where: { name: /\d{2}\z/ }).map(&:id)
    assert_includes output.string, "regular expression filters"
    assert_includes output.string, "pg_trgm"
  ensure
    SearchProduct.logger = previous_logger
  end

  private

  def matches(pattern)
    filtered(name: pattern).order(:id).ids
  end

  def filtered(conditions)
    Tinkick::Filter.new(SearchProduct).apply(SearchProduct.where("description ==> ?", "archive"), conditions)
  end
end
