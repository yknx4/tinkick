# frozen_string_literal: true

require_relative "../integration_helper"
require "tinkick/raw_regex"

class RawRegexTest < TinkickIntegrationTest
  setup do
    SearchProduct.delete_all
    rows = ["abc", "ac", "axc", "abbc", "a😀\nc", "", "abcd", "abc\n", "1", "01", "12", "13", "Moria", "Moria gate", "a&~@#<", "a' OR TRUE --c"].each_with_index.map do |name, index|
      { id: index + 1, name: name, description: "regexp archive", tags: [name], metadata: { values: [name] } }
    end
    SearchProduct.insert_all!(rows)
  end

  def test_ordinary_patterns_are_whole_value_and_keep_the_postgres_regex_path
    sql, binds = compiler.predicate(column(:name), "Moria")

    assert_equal [13], matches("Moria")
    assert_equal [13, 14], matches("Moria.*")
    assert_includes sql, 'COLLATE "C" ~ ?'
    refute_includes sql, "RECURSIVE"
    assert_equal [Tinkick::RegexPattern.new(/\AMoria\z/).compile], binds
  end

  def test_optional_operators_inside_quotes_classes_or_escapes_remain_literals
    ['"a&~@#<"', 'a\\&\\~\\@\\#\\<', 'a[&][~][@][#][<]'].each do |pattern|
      sql, = compiler.predicate(column(:name), pattern)
      refute_includes sql, "RECURSIVE"
      assert_equal [15], matches(pattern)
    end
  end

  def test_selector_handles_leading_class_brackets_carets_and_literal_backslashes_in_quotes
    SearchProduct.find(1).update!(name: "]abc")
    SearchProduct.find(2).update!(name: "#abc")
    SearchProduct.find(3).update!(name: 'x\\anything')

    assert_equal [1, 2], matches("[]#]@")
    assert_equal [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16], matches("[^^]@")
    assert_equal [3], matches('"x\\"@')
  end

  def test_nested_complement_uses_a_bound_automaton_and_whole_value_matches
    sql, binds = compiler.predicate(column(:name), "a(~b)c")

    assert_equal [2, 3, 4, 5, 16], matches("a(~b)c")
    assert_includes sql, "WITH RECURSIVE"
    assert_equal 1, binds.length
    payload = JSON.parse(binds.fetch(0))
    assert_kind_of Array, payload.fetch("edges")
    assert_kind_of Array, payload.fetch("accept")
    refute_includes sql, "a(~b)c"
  end

  def test_intersection_complement_and_empty_language_repetition
    assert_equal [1, 2, 3, 4, 5, 16], matches("a.*&.*c")
    assert_equal [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14, 15, 16], matches("@&~(abc.+)")
    assert_empty matches("(a&aa)*")
    assert_equal [6], matches('#{0,2}')
  end

  def test_whole_value_intersection_and_grouped_complement_use_bound_native_predicates
    SearchProduct.find(1).update!(name: "Moria\narchive 🧙")
    SearchProduct.find(2).update!(name: "Moria and Balrog accounts")
    SearchProduct.find(3).update!(name: "Balrog records")
    pattern = ".*Moria.*&~(.*Balrog.*)"
    sql, binds = compiler.predicate(column(:name), pattern)

    assert_equal [1, 13, 14], matches(pattern)
    refute_includes sql, "RECURSIVE"
    assert_includes sql, " AND "
    assert_includes sql, "NOT "
    assert_equal 2, binds.length
    refute_includes sql, "Moria"
    refute_includes sql, "Balrog"
  end

  def test_native_boolean_structure_preserves_precedence_and_whole_group_nesting
    { "abc|ac&~(abc)" => [1, 2], "((abc|ac)&~(abc))" => [2],
      "~((abc|ac)&~(abc))" => (1..16).to_a - [2] }.each do |pattern, expected|
      sql, = compiler.predicate(column(:name), pattern)
      refute_includes sql, "RECURSIVE"
      assert_equal expected, matches(pattern)
    end
  end

  def test_any_string_atoms_keep_native_matching_in_concatenation_and_repetition
    { "@" => (1..16).to_a, "a@c" => [1, 2, 3, 4, 5, 16], "(@)?" => (1..16).to_a }.each do |pattern, expected|
      sql, = compiler.predicate(column(:name), pattern)
      refute_includes sql, "RECURSIVE"
      assert_equal expected, matches(pattern)
    end
  end

  def test_embedded_boolean_operators_repetition_and_intervals_keep_the_automaton
    ["a(~b)c", "(a&aa)*", "<1-12>", "~abc", "a|b(~c)"].each do |pattern|
      sql, = compiler.predicate(column(:name), pattern)
      assert_includes sql, "WITH RECURSIVE", pattern
    end
  end

  def test_empty_and_null_scalar_values_have_distinct_eligibility
    SearchProduct.find(1).update!(description: nil)
    SearchProduct.find(2).update!(description: "")
    SearchProduct.find(3).update!(description: "abc")
    scope = SearchProduct.where(id: [1, 2, 3])

    assert_equal [2, 3], matches("@", field: :description, scope: scope)
    assert_equal [2], matches("", field: :description, scope: scope)
    assert_equal [2], matches("~(abc)", field: :description, scope: scope)
    assert_equal [2], matches("(@&~(abc))|nomatch", field: :description, scope: scope)
  end

  def test_newline_and_supplementary_characters_work_on_both_paths
    assert_equal [4, 5], matches("a..c")
    assert_equal [5], matches("a😀@c")
    assert_equal [5], matches("[a]😀[^x]c")
  end

  def test_decimal_intervals_preserve_width_and_lucene_numeric_rules
    assert_equal [9, 10, 11], matches("<1-12>")
    assert_equal [10, 11], matches("<01-12>")
    assert_equal [9, 10, 11], matches("<12-1>")
    assert_equal [9], matches("<١-٣>")
  end

  def test_array_matching_keeps_intersection_within_one_element
    SearchProduct.find(1).update!(tags: ["apple", "club"])
    SearchProduct.find(2).update!(tags: [nil, "ab"])
    SearchProduct.find(3).update!(tags: [])
    predicate, binds = compiler.predicate("candidate.value", "a.*&.*b")
    refute_includes predicate, "RECURSIVE"
    scope = SearchProduct.where(id: [1, 2, 3]).where("description ==> ?", "archive")
    sql = "EXISTS (SELECT 1 FROM unnest(tags) AS candidate(value) WHERE #{predicate})"

    assert_equal [2], scope.where(Arel.sql(sql, *binds)).order(:id).ids
  end

  def test_json_string_elements_are_separate_and_non_strings_remain_excluded
    SearchProduct.find(1).update!(metadata: { values: ["apple", "club"] })
    SearchProduct.find(2).update!(metadata: { values: ["ab", 13, nil] })
    SearchProduct.find(3).update!(metadata: { values: [13, nil, true] })
    predicate, binds = compiler.predicate("candidate.value #>> '{}'", "a.*&.*b")
    refute_includes predicate, "RECURSIVE"
    scope = SearchProduct.where(id: [1, 2, 3]).where("description ==> ?", "archive")
    sql = "EXISTS (SELECT 1 FROM jsonb_array_elements(metadata -> 'values') AS candidate(value) WHERE jsonb_typeof(candidate.value) = 'string' AND #{predicate})"

    assert_equal [2], scope.where(Arel.sql(sql, *binds)).order(:id).ids
    all_predicate, all_binds = compiler.predicate("candidate.value #>> '{}'", "@")
    assert_equal [1, 2], scope.where(Arel.sql(sql.sub(predicate, all_predicate), *all_binds)).order(:id).ids
  end

  def test_hostile_pattern_text_cannot_alter_bound_sql_or_other_filters
    pattern = "a(' OR TRUE --)@c"
    sql, binds = compiler.predicate(column(:name), pattern)

    refute_includes sql, "OR TRUE --"
    assert_equal [16], matches(pattern)
    assert_empty matches(pattern, scope: SearchProduct.where(id: 1))
    assert_equal [16], SearchProduct.where(Arel.sql(sql, *binds)).ids
  end

  def test_warnings_distinguish_regular_scans_and_automaton_character_walks
    previous = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)
    compiler.predicate(column(:name), "abc")
    assert_includes output.string, "pg_trgm"
    output.truncate(0)
    output.rewind
    compiler.predicate(column(:name), "@&~abc")
    assert_includes output.string, "character"
    assert_includes output.string.downcase, "long"
    refute_includes output.string, "pg_trgm"
  ensure
    SearchProduct.logger = previous
  end

  def test_invalid_patterns_and_excessive_fast_path_nesting_fail_before_queries
    ["a{3,2}", "[z-a]", "<bad>", "a&", "(" * 300 + "a" + ")" * 300].each do |pattern|
      assert_raises(Tinkick::InvalidQueryError, pattern.inspect) { compiler.predicate(column(:name), pattern) }
    end
  end

  def test_boolean_decomposition_shares_one_compilation_work_budget
    source = "(" * 250 + "a" * 4000 + "&b" + ")" * 250
    error = assert_raises(Tinkick::InvalidQueryError) { compiler.predicate(column(:name), source) }

    assert_includes error.message, "work budget"
  end

  private

  def compiler
    Tinkick::RawRegex.new(SearchProduct)
  end

  def column(name)
    SearchProduct.with_connection do |connection|
      "#{connection.quote_table_name(SearchProduct.table_name)}.#{connection.quote_column_name(name)}"
    end
  end

  def matches(pattern, field: :name, scope: SearchProduct.where("description ==> ?", "archive"))
    sql, binds = compiler.predicate(column(field), pattern)
    scope.where(Arel.sql(sql, *binds)).order(:id).ids
  end
end
