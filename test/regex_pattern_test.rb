# frozen_string_literal: true

require "test_helper"

class RegexPatternTest < Minitest::Test
  def test_raw_strings_compile_without_implicit_substring_matching
    assert_equal Tinkick::RegexPattern.new(/\Aabc\z/).compile, Tinkick::RegexPattern.new("abc").compile
    assert_equal Tinkick::RegexPattern.new(/\A\z/).compile, Tinkick::RegexPattern.new("").compile
  end

  def test_ruby_regexps_retain_their_existing_unanchored_and_ascii_casefolding_behavior
    refute_equal Tinkick::RegexPattern.new(/\Aabc\z/).compile, Tinkick::RegexPattern.new(/abc/).compile
    assert_includes Tinkick::RegexPattern.new(/\Aabc\z/i).compile, "[aA][bB][cC]"
  end
end
