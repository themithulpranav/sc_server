# frozen_string_literal: true

module CandidateRetrieval
  module Strategies
    # Per-source top-K retrieval over an NxM similarity matrix.
    # For each source row, returns up to k {target_index:, score:} hashes
    # sorted by score descending, with deterministic tiebreak on target_index ascending.
    class TopK
      def initialize(k:)
        unless k.is_a?(Integer) && k.positive?
          raise ArgumentError, "k must be a positive Integer, got #{k.inspect}"
        end

        @k = k
      end

      def select(scores:)
        rows = Array(scores)
        return [] if rows.empty?

        rows.map do |row|
          Array(row).each_with_index
                    .map { |s, j| { target_index: j, score: s.to_f } }
                    .sort_by { |c| [-c[:score], c[:target_index]] }
                    .first(@k)
        end
      end
    end
  end
end
