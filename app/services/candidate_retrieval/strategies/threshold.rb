# frozen_string_literal: true

module CandidateRetrieval
  module Strategies
    # Per-source threshold retrieval over an NxM similarity matrix.
    # For each source row, returns every {target_index:, score:} whose score
    # is strictly greater than `min`, sorted by score descending with
    # deterministic tiebreak on target_index ascending.
    class Threshold
      def initialize(min:)
        raise ArgumentError, "min must be Numeric, got #{min.inspect}" unless min.is_a?(Numeric)

        @min = min.to_f
      end

      def select(scores:)
        rows = Array(scores)
        return [] if rows.empty?

        rows.map do |row|
          Array(row).each_with_index
                    .select { |s, _j| s.to_f > @min }
                    .map { |s, j| { target_index: j, score: s.to_f } }
                    .sort_by { |c| [-c[:score], c[:target_index]] }
        end
      end
    end
  end
end
