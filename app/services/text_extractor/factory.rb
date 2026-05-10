module TextExtractor
  module Factory
    REGISTRY = {
      pdf: PdfService,
      url: UrlService
    }.freeze

    def self.build(type, input)
      klass = REGISTRY[type]
      raise ArgumentError, "Unknown extractor #{type}" unless klass

      klass.new(input)
    end
  end
end
