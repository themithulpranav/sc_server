# frozen_string_literal: true

module Representors
  class Factory
    def self.build(_strategy = :sentence_transformers)
      Strategies::SentenceTransformers.new
    end
  end
end
