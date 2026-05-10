require "digest"
require "fileutils"
require "json"
require "net/http"
require "uri"

module Gemini
  module Chat
    ENDPOINT_BASE = "https://generativelanguage.googleapis.com/v1beta/models".freeze
    DEFAULT_MODEL = "gemini-2.5-flash".freeze

    def self.call(prompt, cache_key: nil)
      model = ENV["GEMINI_MODEL"].presence || DEFAULT_MODEL
      path = cache_file_path(model, cache_key) if use_file_cache?(cache_key)

      if path && File.file?(path)
        Rails.logger.info("[Gemini::Chat] cache hit key=#{cache_key.inspect} path=#{path}")
        return JSON.parse(File.read(path))
      end

      Rails.logger.info("[Gemini::Chat] hitting API with prompt (#{prompt.length} chars)")

      api_key = ENV["GEMINI_API_KEY"]
      raise "Gemini::Chat missing GEMINI_API_KEY" if api_key.blank?

      uri = URI("#{ENDPOINT_BASE}/#{model}:generateContent?key=#{api_key}")

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = {
        contents: [
          {
            parts: [{ text: prompt }]
          }
        ]
      }.to_json

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 600, open_timeout: 60) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "Gemini::Chat request failed: status=#{response.code}, body=#{response.body}"
      end

      raw = JSON.parse(response.body)
      text = raw.dig("candidates", 0, "content", "parts", 0, "text").to_s
      if text.blank?
        raise "Gemini::Chat received empty text: #{raw.inspect}"
      end

      parsed = JSON.parse(clean_json_block(text))
      Rails.logger.info("[Gemini::Chat] parsed content: #{parsed.inspect}")

      if path
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate(parsed))
        Rails.logger.info("[Gemini::Chat] cache write key=#{cache_key.inspect} path=#{path}")
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
      Rails.root.join("tmp", "cache", "gemini", "#{slug}_#{digest}.json")
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
  end
end
