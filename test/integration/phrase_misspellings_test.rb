# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/model"

class PhraseMisspellingsTest < TinkickIntegrationTest
  def test_phrase_matching_ignores_fuzzy_distance_and_expansion_options
    options = [true, false, { edit_distance: 0 }, { edit_distance: 2 },
      { distance: 2 }, { edit_distance: 3, transpositions: false }, { max_expansions: 1 }]
    options.each do |misspellings|
      assert_equal(["Red Apple"], search("red apple", match: :phrase, misspellings: misspellings).map(&:name))
      assert_empty(search("rde apple", match: :phrase, misspellings: misspellings))
      assert_empty(search("apple red", match: :phrase, misspellings: misspellings))
    end
  end

  def test_phrase_and_two_edit_word_fields_can_share_misspellings_options
    fields = [{ name: :word }, { description: :phrase }]

    assert_equal(["Red Apple"], search("papel", fields: fields, misspellings: { edit_distance: 2 }).map(&:name))
    assert_equal(["Green Pear"], search("ripe fruit", fields: fields, misspellings: { edit_distance: 2 }).map(&:name))
  end

  private

  def search(term, **options)
    @model ||= Class.new(SearchProduct) { tinkick searchable: [:name, :description] }
    @model.search(term, fields: [:name], **options)
  end
end
