# frozen_string_literal: true

require "test_helper"
require "tinkick/regex_automaton"

class RegexAutomatonTest < Minitest::Test
  def test_literals_use_unicode_codepoints_and_match_the_complete_string
    automaton = klass.literal("a😀\n")

    assert_language(automaton, ["a😀\n"], ["", "a", "a😀", "xa😀\n", "a😀\nx"])
    assert_equal(4, automaton.edges.length)
  end

  def test_character_intervals_include_newlines_and_supplementary_characters
    assert_language(klass.any, ["a", "\n", "😀", "\u{10ffff}"], ["", "ab"])
    assert_language(klass.characters(0x1f600, 0x1f601), ["😀", "😁"], ["😂", "a"])
  end

  def test_union_and_intersection_are_whole_language_operations
    left = klass.literal("apple").union(klass.literal("ab"))
    right = klass.literal("club").union(klass.literal("ab"))

    assert_language(left.union(right), ["apple", "club", "ab"], ["", "a", "b"])
    assert_language(left.intersection(right), ["ab"], ["apple", "club", ""])
  end

  def test_complement_inside_concatenation_handles_variable_length_strings
    automaton = klass.literal("a").concatenate(klass.literal("b").complement).concatenate(klass.literal("c"))

    assert_language(automaton, ["ac", "axc", "abbc", "a😀\nc"], ["abc", "a", "c", "xac"])
  end

  def test_complement_is_over_all_unicode_strings_including_empty
    assert_language(klass.empty.complement, ["", "a", "\n", "😀😀"], [])
    assert_language(klass.all.complement, [], ["", "a", "\n"])
    assert_language(klass.literal("ab").complement.complement, ["ab"], ["", "a", "abc"])
  end

  def test_repetition_keeps_pinned_lucene_empty_language_behavior
    # Lucene 9.12.2 Operations.repeat returns the empty automaton unchanged.
    assert_language(klass.empty.repeat, [], ["", "a"])
    assert_language(klass.empty.bounds(0, nil), [], [""])
    assert_language(klass.empty.bounds(0, 2), [""], ["a"])
    assert_language(klass.empty.bounds(0, 0), [""], ["a"])
    assert_language(klass.literal("ab").repeat, ["", "ab", "abab"], ["a", "aba"])
  end

  def test_bounded_and_unbounded_repetition_do_not_repeat_only_the_last_character
    assert_language(klass.literal("ab").bounds(1, 3), ["ab", "abab", "ababab"], ["", "a", "abb", "abababab"])
    assert_language(klass.literal("ab").bounds(2, nil), ["abab", "ababab"], ["", "ab"])
  end

  def test_decimal_intervals_preserve_fixed_width_and_variable_leading_zeros
    assert_language(klass.interval(1, 12, 2), ["01", "09", "12"], ["1", "001", "00", "13"])
    assert_language(klass.interval(12, 1), ["1", "01", "00012", "9"], ["", "0", "13", "a"])
  end

  def test_full_integer_interval_is_compact_without_enumerating_values
    automaton = klass.interval(0, 2_147_483_647)

    assert_language(automaton, ["0", "000", "2147483647", "002147483647"], ["2147483648", "-1", ""])
    assert_operator(automaton.edges.length, :<, 30)
  end

  def test_minimization_merges_equivalent_suffix_states_and_rejecting_sink
    automaton = klass.new([
      [[97, 97, 1], [98, 98, 2], [120, 120, 4]],
      [[99, 99, 3]],
      [[99, 99, 3]],
      [],
      [[0, 0x10ffff, 4]],
    ], [3]).minimize

    assert_language(automaton, ["ac", "bc"], ["", "a", "b", "xc", "xxx"])
    assert_equal(3, automaton.edges.length)
    assert_equal([[97, 98, 1]], automaton.edges.first)
  end

  def test_minimization_merges_equivalent_states_inside_a_cycle
    edges = Array.new(12) { |state| [[97, 97, (state + 1) % 12]] }
    automaton = klass.new(edges, [0, 3, 6, 9]).minimize

    assert_equal(3, automaton.edges.length)
    (0..24).each { |length| assert_equal(length % 3 == 0, automaton.run("a" * length)) }
    refute(automaton.run("aaab"))
  end

  def test_invalid_intervals_and_repetition_fail_before_building_a_graph
    assert_raises(Tinkick::InvalidQueryError) { klass.characters(-1) }
    assert_raises(Tinkick::InvalidQueryError) { klass.characters(2, 1) }
    assert_raises(Tinkick::InvalidQueryError) { klass.characters(0x110000) }
    assert_raises(Tinkick::InvalidQueryError) { klass.interval(-1, 2) }
    assert_raises(Tinkick::InvalidQueryError) { klass.interval(1, 100, 2) }
    assert_raises(Tinkick::InvalidQueryError) { klass.literal("a").bounds(-1, 2) }
    assert_raises(Tinkick::InvalidQueryError) { klass.literal("a").bounds(3, 2) }
  end

  def test_minimization_discards_unreachable_accepting_states
    automaton = klass.new([[[97, 97, 1]], [], [[98, 98, 2]]], [1, 2]).minimize

    assert_equal(2, automaton.edges.length)
    assert_language(automaton, ["a"], ["", "b", "bb"])
  end

  def test_long_deterministic_language_is_not_rejected_by_a_ten_thousand_state_ceiling
    text = "a" * 10_001
    automaton = klass.literal(text).minimize

    assert_equal(10_002, automaton.edges.length)
    assert(automaton.run(text))
    refute(automaton.run(text.chop))
  end

  def test_universal_and_epsilon_repetitions_simplify_before_allocating_states
    assert_equal(1, klass.all.bounds(10_001, 10_001).edges.length)
    assert_equal(1, klass.epsilon.bounds(10_001, nil).edges.length)
    assert_language(klass.all.bounds(10_001, 10_001), ["", "a", "😀\n"], [])
  end

  def test_compilation_budget_is_shared_by_compositions_and_reports_adapter_limit
    work = klass::Work.new(70)
    left = klass.literal("abcdefghij", work: work)
    right = klass.literal("klmnopqrst", work: work)
    error = assert_raises(Tinkick::InvalidQueryError) { left.concatenate(right) }

    assert_match(/regular expression compilation work budget/i, error.message)
    refute_match(/unsupported|TIN|determinized_states/, error.message)
  end

  def test_expensive_repetition_fails_before_allocating_an_unbounded_graph
    error = assert_raises(Tinkick::InvalidQueryError) { klass.literal("ab").bounds(1_000_000, 1_000_000) }

    assert_match(/compilation work budget/, error.message)
  end

  def test_operations_preserve_their_inputs_and_export_immutable_transitions
    left = klass.literal("a")
    original = Marshal.dump([left.edges, left.finals])
    left.union(klass.literal("b")).repeat.complement

    assert_equal(original, Marshal.dump([left.edges, left.finals]))
    assert(left.edges.frozen?)
    assert(left.edges.first.frozen?)
    assert(left.edges.first.first.frozen?)
    assert(left.finals.frozen?)
  end

  def test_language_identities_hold_for_a_small_complete_corpus
    a = klass.literal("a").union(klass.literal("ab"))
    b = klass.literal("b").repeat
    union_complement = a.union(b).complement
    complement_intersection = a.complement.intersection(b.complement)
    samples = [""] + (1..4).flat_map { |length| ["a", "b", "😀"].repeated_permutation(length).map(&:join) }

    samples.each do |sample|
      assert_equal(union_complement.run(sample), complement_intersection.run(sample), sample.inspect)
    end
  end

  private

  def klass
    Tinkick::RegexAutomaton
  end

  def assert_language(automaton, accepted, rejected)
    accepted.each { |text| assert(automaton.run(text), "expected #{text.inspect} to match") }
    rejected.each { |text| refute(automaton.run(text), "expected #{text.inspect} not to match") }
  end
end
