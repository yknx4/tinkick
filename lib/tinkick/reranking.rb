# frozen_string_literal: true

module Tinkick
  module Reranking
    class << self
      def rrf(first_ranking, *rankings, k: 60)
        lists = [first_ranking, *rankings].map { |ranking| ranking.to_ary }
        ranks = lists.map do |ranking|
          ranking.map.with_index.to_h { |result, index| [result, index + 1] }
        end
        results = lists.flat_map { |ranking| ranking }

        # @type var fused: Array[reranked_result]
        fused = results.uniq.map do |result|
          score = ranks.sum do |rank|
            position = rank[result]
            position ? 1.0 / (k + position) : 0.0
          end
          { result: result, score: score }
        end
        fused.sort_by { |entry| -entry.fetch(:score) }
      end
    end
  end
end
