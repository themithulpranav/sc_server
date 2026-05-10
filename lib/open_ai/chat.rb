module OpenAi
  module Chat
    def self.call(prompt)
      Rails.logger.info("[OpenAi::Chat] hitting API with prompt (#{prompt.length} chars)")
      Rails.logger.info("[OpenAi::Chat] full prompt:\n#{prompt}")

      client = OpenAI::Client.new
      response = client.chat(
        parameters: {
          model: "qwen/qwen3-coder:free",
          response_format: { type: "json_object" },
          messages: [{ role: "user", content: prompt }],
          temperature: 0.4
        }
      )

      Rails.logger.info("[OpenAi::Chat] full raw response: #{response.inspect}")
      content = response.dig("choices", 0, "message", "content")
      if content.blank?
        raise "OpenAi::Chat received empty content. finish_reason=#{response.dig("choices", 0, "finish_reason").inspect}, model=#{response["model"].inspect}"
      end
      parsed = JSON.parse(content)
      Rails.logger.info("[OpenAi::Chat] parsed content: #{parsed.inspect}")
      parsed
    end
  end
end
