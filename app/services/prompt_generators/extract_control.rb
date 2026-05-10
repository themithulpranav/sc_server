module PromptGenerators
  class ExtractControl < BaseGenerator
    def generate
      <<~PROMPT.strip
        You are a compliance analyst. From the following document, extract every distinct security, privacy, compliance, or operational control statement.
        Respond ONLY as a JSON object of the exact shape: {"controls": ["<control text 1>", "<control text 2>"]}.
        Do not add commentary. Document:

        #{@text}
      PROMPT
    end
  end
end
