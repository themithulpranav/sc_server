# frozen_string_literal: true

module SimilarityScoring
  module Strategies
    # Cosine similarity for vectors that are already L2-normalized upstream
    # (see scripts/embed_texts.py). For unit vectors, cosine == dot product.
    class Cosine
      def score(source_embeddings:, target_embeddings:)
        src = Array(source_embeddings)
        tgt = Array(target_embeddings)
        return [] if src.empty? || tgt.empty?

        dim = validate_dims!(src, tgt)

        src.map do |a|
          tgt.map do |b|
            sum = 0.0
            i = 0
            while i < dim
              sum += a[i] * b[i]
              i += 1
            end
            sum.clamp(-1.0, 1.0).round(6)
          end
        end
      end

      private

      def validate_dims!(src, tgt)
        first = src.first
        unless first.is_a?(Array) && first.length.positive?
          raise ArgumentError, "source_embeddings[0] must be a non-empty Array, got #{first.inspect}"
        end

        dim = first.length

        src.each_with_index do |vec, i|
          unless vec.is_a?(Array) && vec.length == dim
            raise ArgumentError,
                  "source_embeddings[#{i}] has length #{vec.respond_to?(:length) ? vec.length : 'n/a'}, expected #{dim}"
          end
        end

        tgt.each_with_index do |vec, j|
          unless vec.is_a?(Array) && vec.length == dim
            raise ArgumentError,
                  "target_embeddings[#{j}] has length #{vec.respond_to?(:length) ? vec.length : 'n/a'}, expected #{dim}"
          end
        end

        dim
      end
    end
  end
end
