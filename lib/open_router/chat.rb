require "digest"
require "fileutils"
require "json"
require "openai"

module OpenRouter
  module Chat
    DEFAULT_MODEL = "meta-llama/llama-3.3-70b-instruct:free".freeze

    def self.call(prompt, cache_key: nil)
      model = ENV["OPENROUTER_MODEL"].presence || DEFAULT_MODEL
      path = cache_file_path(model, cache_key) if use_file_cache?(cache_key)

      if path && File.file?(path)
        Rails.logger.info("[OpenRouter::Chat] cache hit key=#{cache_key.inspect} path=#{path}")
        return JSON.parse(File.read(path))
      end

      Rails.logger.info("[OpenRouter::Chat] hitting API model=#{model} prompt=#{prompt.length} chars")

      api_key = ENV["OPENROUTER_API_KEY"]
      raise "OpenRouter::Chat missing OPENROUTER_API_KEY" if api_key.blank?

      client = OpenAI::Client.new(
        access_token: api_key,
        uri_base: "https://openrouter.ai/api/v1",
        request_timeout: 600,
        extra_headers: {
          "HTTP-Referer" => ENV["OPENROUTER_REFERER"].presence || "http://localhost:3000",
          "X-Title" => ENV["OPENROUTER_APP_TITLE"].presence || "easyship-challenges-live-code"
        }
      )

      response = client.chat(
        parameters: {
          model: model,
          messages: [
            { role: "system", content: "You are a helpful assistant that always responds with valid JSON only. Do not wrap the JSON in markdown code fences and do not include any prose around it." },
            { role: "user", content: prompt }
          ],
          temperature: 0
        }
      )

      served_model  = response.dig("model")
      finish_reason = response.dig("choices", 0, "finish_reason")
      usage         = response.dig("usage")
      Rails.logger.info(
        "[OpenRouter::Chat] response served_model=#{served_model.inspect} " \
        "finish_reason=#{finish_reason.inspect} usage=#{usage.inspect}"
      )

      text = response.dig("choices", 0, "message", "content").to_s
      if text.blank?
        Rails.logger.error(
          "[OpenRouter::Chat] empty content from API (requested=#{model.inspect} " \
          "served=#{served_model.inspect}). Returning {} sentinel. response=#{response.inspect}"
        )
        return {}
      end

      cleaned = clean_json_block(text)
      parsed =
        begin
          JSON.parse(cleaned)
        rescue JSON::ParserError
          parse_first_json_object(cleaned)
        end

      if parsed.nil?
        Rails.logger.error(
          "[OpenRouter::Chat] could not parse JSON from response " \
          "(requested=#{model.inspect} served=#{served_model.inspect} " \
          "finish_reason=#{finish_reason.inspect}). Returning {} sentinel. raw=#{text.inspect}"
        )
        return {}
      end

      Rails.logger.info("[OpenRouter::Chat] parsed content: #{parsed.inspect}")

      if path
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate(parsed))
        Rails.logger.info("[OpenRouter::Chat] cache write key=#{cache_key.inspect} path=#{path}")
      end

      parsed
    end

    def self.use_file_cache?(cache_key)
      cache_key.present? && Rails.env.development?
    end
    private_class_method :use_file_cache?

    def self.cache_file_path(model, cache_key)
      slug = model.to_s.gsub(/[^\w.\-]+/, "_")
      digest = Digest::SHA256.hexdigest("#{model}\n#{cache_key}")
      Rails.root.join("tmp", "cache1", "open_router", "#{slug}_#{digest}.json")
    end
    private_class_method :cache_file_path

    def self.clean_json_block(text)
      stripped = text.strip
      return stripped unless stripped.start_with?("```")

      stripped
        .sub(/\A```(?:json)?\s*/i, "")
        .sub(/\s*```\z/, "")
        .strip
    end
    private_class_method :clean_json_block

    # Some free models prepend short prose before the JSON. As a fallback,
    # extract the first balanced { ... } or [ ... ] from the text.
    def self.parse_first_json_object(text)
      starts = ["{", "["]
      idx = text.index(/[{\[]/)
      return nil unless idx

      open_char = text[idx]
      close_char = open_char == "{" ? "}" : "]"

      depth = 0
      in_string = false
      escape = false
      i = idx
      while i < text.length
        ch = text[i]
        if in_string
          if escape
            escape = false
          elsif ch == "\\"
            escape = true
          elsif ch == "\""
            in_string = false
          end
        else
          if ch == "\""
            in_string = true
          elsif ch == open_char
            depth += 1
          elsif ch == close_char
            depth -= 1
            if depth.zero?
              candidate = text[idx..i]
              return JSON.parse(candidate) rescue nil
            end
          end
        end
        i += 1
      end

      nil
    end
    private_class_method :parse_first_json_object
  end
end
