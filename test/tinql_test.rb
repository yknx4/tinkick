# frozen_string_literal: true

require_relative "test_helper"

class TinqlTest < Minitest::Test
  def test_nested_operators_preserve_parentheses_and_literal_escaping
    expression = {
      boost: { and: [
        { near: [{ phrase: ["quartz", nil, ["cedar", "amber"]], slop: 1 }, "harbor"], distance: 2 },
        { at_least: ["stone", { in_first: "map", percent: 50 }], count: 1 },
      ] },
      factor: 2.5,
    }

    assert_equal '((("quartz _ [cedar amber]"~1) NEAR/2 ("harbor")) AND (AT LEAST 1 OF [("stone") (("map") IN FIRST 50%)]))^2.5',
      Tinkick::Tinql.new.compile(expression)
    assert_equal '"a\\_b\\[c\\]"', Tinkick::Tinql.new.compile("a_b[c]")
  end

  def test_position_and_minimum_match_boundaries_keep_their_distinct_syntax
    cases = [
      [{ in_first: "map", words: 1 }, '("map") IN FIRST 1 WORDS'],
      [{ in_last: "map", percent: 100 }, '("map") IN LAST 100%'],
      [{ in_middle: "map", percent: 1 }, '("map") IN MIDDLE 1%'],
      [{ at_least: ["map"], count: 1 }, 'AT LEAST 1 OF [("map")]'],
      [{ at_least: ["map"], percent: 100 }, 'AT LEAST 100% OF [("map")]'],
      [{ all_of: ["map"] }, 'ALL OF [("map")]'],
      [{ any_of: ["map"] }, '[("map")]'],
    ]
    cases.each { |expression, expected| assert_equal expected, Tinkick::Tinql.new.compile(expression) }
  end

  def test_validation_order_and_messages_are_preserved
    cases = [
      [{ near: [nil], distance: -1 }, "tinql near requires two expressions"],
      [{ near: [nil, nil], distance: -1 }, "tinql expects an integer >= 0"],
      [{ before: [nil] }, "tinql before requires two expressions"],
      [{ boost: nil, factor: -1 }, "tinql boost factor must be a finite number between 0 and 10000"],
      [{ in_first: nil, words: 0 }, "tinql requires a literal string or an expression hash with one operator"],
      [{ at_least: [nil], count: 0 }, "tinql requires a literal string or an expression hash with one operator"],
      [{ in_first: "map", words: 1, percent: 50 }, "tinql position requires exactly one of words or percent"],
      [{ at_least: ["map"], count: 1, percent: 50 }, "tinql at_least requires exactly one of count or percent"],
      [{ in_last: "map", percent: 101 }, "tinql percent cannot exceed 100"],
      [{ at_least: ["map"], percent: 101 }, "tinql percent cannot exceed 100"],
      [{ raw: "*", typo: true }, "Unknown tinql options: typo"],
    ]
    cases.each do |expression, message|
      error = assert_raises(ArgumentError) { Tinkick::Tinql.new.compile(expression) }
      assert_equal message, error.message, expression.inspect
    end
  end
end
