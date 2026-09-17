# frozen_string_literal: true

require "test_helper"
require "tinkick/lucene_pattern"

class LucenePatternTest < Minitest::Test
  def test_plain_patterns_are_whole_value_case_sensitive_unicode_languages
    assert_language("café😀", ["café😀"], ["Café😀", "xcafé😀", "café😀x", ""])
    assert_language("a.b", ["a\nb", "a😀b"], ["ab", "a😀😀b"])
    assert_language("", [""], ["a"])
  end

  def test_intersection_binds_more_tightly_than_union
    assert_language("a|b&c", ["a"], ["b", "c", "bc"])
    assert_language("(a|b)&b", ["b"], ["a", "ab"])
  end

  def test_nested_complement_is_a_language_inside_concatenation
    assert_language("a(~b)c", ["ac", "axc", "abbc", "a😀\nc"], ["abc", "a", "c"])
    assert_language("@&~(abc.+)", ["", "abc", "ab", "xabcx"], ["abcd", "abc\n", "abc😀"])
  end

  def test_complement_binds_before_concatenation_and_repetition
    assert_language("~ab", ["b", "bb", "aab"], ["ab", "a", ""])
    assert_language("~a*", ["", "b", "bb", "aa", "aab"], ["a"])
    assert_language("~(a*)", ["b", "ab", "a\n"], ["", "a", "aa"])
  end

  def test_pinned_empty_language_repetition_and_optional_forms
    assert_language("(a&aa)*", [], ["", "a", "aa"])
    assert_language("#*", [], ["", "#"])
    assert_language('#{0,}', [], [""])
    assert_language('#{0,2}', [""], ["a"])
    assert_language("#?", [""], ["#"])
    assert_language("()", [""], ["()"])
  end

  def test_bounded_and_stacked_repetition
    assert_language("(ab){1,3}", ["ab", "abab", "ababab"], ["", "abb", "abababab"])
    assert_language("a{2}{2}", ["aaaa"], ["aa", "aaa"])
    assert_language("ab?c+", ["ac", "acc", "abc", "abccc"], ["a", "ab", "abbc"])
  end

  def test_quoted_literals_do_not_interpret_operators_or_backslashes
    assert_language('"a&~@#[]"', ["a&~@#[]"], ["a", ""])
    assert_language('"a\\db"', ['a\\db'], ["a1b", "adb"])
    assert_language('""', [""], ["a"])
  end

  def test_character_classes_ranges_negation_and_escaped_punctuation
    assert_language("[a-c]+", ["a", "abc", "cc"], ["A", "d", ""])
    assert_language("[^a]", ["b", "\n", "😀"], ["a", "", "bb"])
    assert_language('[\\.-0]', [".", "/", "0"], ["-", "1", "a"])
    assert_language('[\\!-\\.]', ["!", "#", "-", "."], [" ", "/"])
    assert_language("[😀-😂]", ["😀", "😁", "😂"], ["a", "😃"])
    assert_language("[]]", ["]"], ["[", ""])
  end

  def test_predefined_classes_are_pinned_ascii_classes
    assert_language('\\d+', ["0", "123"], ["١", "a", ""])
    assert_language('\\w+', ["a_Z09"], ["é", " "])
    assert_language('\\s', [" ", "\t", "\n", "\r"], ["\v", "\f", "\u00a0", "s"])
    assert_language('[\\D]', ["a", "😀"], ["1", ""])
    assert_language('\\S', ["a", "\v"], ["\n", ""])
    assert_language('\\W', ["é", " "], ["a", "9", "_"])
  end

  def test_escaped_punctuation_and_lucene_literal_anchor_characters
    assert_language('\\@\\#\\&\\~', ["@#&~"], ["", "@"])
    assert_language('\\\\', ['\\'], ["", "a"])
    assert_language("^a$", ["^a$"], ["a"])
    assert_language("**", ["", "*", "***"], ["a"])
    assert_language("|a", ["|a"], ["a", ""])
    assert_language("a||b", ["a", "|b"], ["b", ""])
  end

  def test_decimal_intervals_preserve_width_swap_bounds_and_allow_variable_leading_zeros
    assert_language("<01-12>", ["01", "09", "12"], ["1", "001", "00", "13"])
    assert_language("<12-1>", ["1", "01", "00012"], ["0", "13", ""])
    assert_language("<+1-2>", ["1", "01", "2"], ["+1", "3"])
    assert_language("x<0-2147483647>y", ["x0y", "x002147483647y"], ["x2147483648y", "xy"])
  end

  def test_invalid_syntax_raises_actionable_query_errors
    ["(", "a)", "[", "[]", "[z-a]", '"abc', "a|", "a&", "~", "\\", '\\q',
      "a{}", "a{,2}", "a{2,1}", "a{2", "a{2147483648}", "a{1,2147483648}",
      "<1-2", "<1->", "<-1-2>", "<1-2-3>", "<1.0-2>", "<0-2147483648>", "<named>", "<>"].each do |pattern|
      error = assert_raises(Tinkick::InvalidQueryError, pattern.inspect) { compile(pattern) }
      assert_match(/regular expression|automaton/i, error.message, pattern.inspect)
    end
  end

  def test_interval_endpoints_follow_java_bmp_decimal_parsing_but_counts_are_ascii
    assert_language("<١-٣>", ["1", "2", "3"], ["١", "01", "4"])
    assert_language("<０１-１２>", ["01", "12"], ["1", "０１", "13"])
    assert_language("<+١-٢>", ["1", "01", "2"], ["+1", "3"])
    assert_raises(Tinkick::InvalidQueryError) { compile("a{١}") }
    assert_raises(Tinkick::InvalidQueryError) { compile("<𝟙-𝟛>") }
  end

  def test_large_deterministic_literal_stays_linear_and_shares_one_work_counter
    text = "a" * 10_001
    automaton = compile(text)

    assert_equal(10_002, automaton.edges.length)
    assert(automaton.run(text))
    refute(automaton.run(text.chop))
    assert_equal(1, compile("@{10001}").edges.length)
  end

  def test_excessive_nesting_is_an_adapter_query_error_instead_of_a_ruby_stack_error
    error = assert_raises(Tinkick::InvalidQueryError) { compile("(" * 300 + "a" + ")" * 300) }

    assert_match(/nesting.*budget/i, error.message)
    assert_language("~" * 10_000 + "a", ["a"], ["", "b"])
  end

  def test_compilation_work_is_cumulative_across_sibling_expressions
    error = assert_raises(Tinkick::InvalidQueryError) { compile(("(abc){1000}|" * 100) + "z") }

    assert_match(/compilation work budget/i, error.message)
  end

  private

  def compile(pattern)
    Tinkick::LucenePattern.new(pattern).compile
  end

  def assert_language(pattern, accepted, rejected)
    automaton = compile(pattern)
    accepted.each { |text| assert(automaton.run(text), "#{pattern.inspect} should match #{text.inspect}") }
    rejected.each { |text| refute(automaton.run(text), "#{pattern.inspect} should not match #{text.inspect}") }
  end
end
