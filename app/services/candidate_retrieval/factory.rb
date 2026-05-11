# frozen_string_literal: true

module CandidateRetrieval
  class Factory
    def self.build(strategy = :top_k, **opts)
      case strategy
      when :top_k     then Strategies::TopK.new(k: opts.fetch(:k, 4))
      when :threshold then Strategies::Threshold.new(min: opts.fetch(:min, 0.4))
      else raise ArgumentError, "unknown retrieval strategy: #{strategy.inspect}"
      end
    end
  end
end
