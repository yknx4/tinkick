# frozen_string_literal: true

require_relative "test_helper"

class RerankingTest < Minitest::Test
  RankedList = Struct.new(:values) do
    def to_ary
      values
    end
  end

  def test_combines_rank_positions_and_returns_original_results
    bear = { name: "Bear" }.freeze
    cat = { name: "Cat" }.freeze
    dog = { name: "Dog" }.freeze
    results = Tinkick::Reranking.rrf([bear, cat], [dog, bear, cat])

    assert_equal [bear, cat, dog], results.map { |entry| entry.fetch(:result) }
    assert_same bear, results.first.fetch(:result)
    assert_in_delta 1.0 / 61 + 1.0 / 62, results.fetch(0).fetch(:score)
    assert_in_delta 1.0 / 62 + 1.0 / 63, results.fetch(1).fetch(:score)
    assert_in_delta 1.0 / 61, results.fetch(2).fetch(:score)
  end

  def test_accepts_multiple_array_like_rankings_and_custom_k
    results = Tinkick::Reranking.rrf(RankedList.new([:moria, :shire]),
      RankedList.new([:shire]), RankedList.new([:moria]), k: 1.5)

    assert_equal [:moria, :shire], results.map { |entry| entry.fetch(:result) }
    assert_in_delta 2.0 / 2.5, results.fetch(0).fetch(:score)
    assert_in_delta 1.0 / 3.5 + 1.0 / 2.5, results.fetch(1).fetch(:score)
  end

  def test_single_and_empty_rankings
    assert_empty Tinkick::Reranking.rrf([])
    assert_empty Tinkick::Reranking.rrf([], [])
    assert_equal [{ result: :moria, score: 1.0 }, { result: :shire, score: 0.5 }],
      Tinkick::Reranking.rrf([], [:moria, :shire], [], k: 0)
  end

  def test_equal_scores_preserve_first_encounter_order
    results = Tinkick::Reranking.rrf([:shire, :moria], [:moria, :shire])

    assert_equal [:shire, :moria], results.map { |entry| entry.fetch(:result) }
    assert_equal results.fetch(0).fetch(:score), results.fetch(1).fetch(:score)
  end

  def test_duplicate_results_use_the_last_position_within_each_ranking
    results = Tinkick::Reranking.rrf([:shire, :moria, :shire], [:shire], k: 0)

    assert_equal [:shire, :moria], results.map { |entry| entry.fetch(:result) }
    assert_in_delta 1.0 / 3 + 1, results.fetch(0).fetch(:score)
    assert_in_delta 0.5, results.fetch(1).fetch(:score)
  end

  def test_input_rankings_are_not_mutated
    first = [:shire, :moria].freeze
    second = [:moria, :gondor].freeze
    Tinkick::Reranking.rrf(first, second)

    assert_equal [:shire, :moria], first
    assert_equal [:moria, :gondor], second
  end
end
