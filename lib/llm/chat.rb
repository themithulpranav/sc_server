module Llm
  module Chat
    DEFAULT_PROVIDER = "openrouter".freeze

    def self.call(prompt, cache_key: nil)
      Rails.logger.info("[Llm::Chat] provider=#{provider_name} cache_key=#{cache_key.inspect}")
      provider.call(prompt, cache_key: cache_key)
    end

    def self.provider
      case provider_name
      when "gemini"     then Gemini::Chat
      when "openrouter" then OpenRouter::Chat
      else
        raise ArgumentError,
              "unknown LLM_PROVIDER: #{provider_name.inspect} (expected 'gemini' or 'openrouter')"
      end
    end

    def self.provider_name
      ENV.fetch("LLM_PROVIDER", DEFAULT_PROVIDER).to_s.downcase.strip
    end
  end
end
