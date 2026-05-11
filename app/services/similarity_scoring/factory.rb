# frozen_string_literal: true

module SimilarityScoring
  class Factory
    def self.build(strategy = :cosine)
      case strategy
      when :cosine then Strategies::Cosine.new
      else raise ArgumentError, "unknown similarity strategy: #{strategy.inspect}"
      end
    end
  end
end
