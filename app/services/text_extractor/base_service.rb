module TextExtractor
  class BaseService
    def initialize(input)
      @input = input
    end

    def call
      raise NotImplementedError, "#{self.class} must implement #call"
    end
  end
end
