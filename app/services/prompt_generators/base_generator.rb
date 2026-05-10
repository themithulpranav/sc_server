module PromptGenerators
  class BaseGenerator
    def initialize(text)
      @text = text
    end

    def generate
      raise NotImplementedError, "#{self.class} must implement #generate"
    end
  end
end
