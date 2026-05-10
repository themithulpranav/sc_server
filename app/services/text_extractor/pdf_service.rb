require "json"
require "open3"

module TextExtractor
  class PdfService < BaseService
    def call
      label = @input.try(:original_filename) || @input.inspect

      Rails.logger.info(
        "[TextExtractor::PdfService] extracting structured PDF text: #{label}"
      )

      blocks = extract_blocks

      formatted_text = build_ai_input(blocks)

      Rails.logger.info(
        "[TextExtractor::PdfService] extracted #{formatted_text.length} chars from #{label}"
      )

      formatted_text
    end

    private

    def extract_blocks
      script_path = Rails.root.join("scripts/pdf_extract.py")

      stdout, stderr, status = Open3.capture3(
        "python3",
        script_path.to_s,
        @input.path
      )

      unless status.success?
        raise "PDF extraction failed: #{stderr}"
      end

      JSON.parse(stdout)
    end

    def build_ai_input(blocks)
      prioritized_blocks = prioritize_blocks(blocks)

      prioritized_blocks.map do |block|
        next if block["type"] == "heading"

        <<~TEXT
          PAGE: #{block["page"]}
          SECTION: #{Array(block["section"]).join(" > ")}
          TEXT: #{block["text"]}
        TEXT
      end.compact.join("\n\n")
    end

    def prioritize_blocks(blocks)
      blocks
        .select do |block|
        block["control_candidate_score"].to_i >= 1
      end
        .sort_by do |block|
        -block["control_candidate_score"].to_i
      end
    end
  end
end