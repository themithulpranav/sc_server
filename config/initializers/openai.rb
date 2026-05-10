OpenAI.configure do |config|
  config.access_token = ENV["OPENROUTER_API_KEY"]
  config.uri_base = "https://openrouter.ai/api/v1"
end
