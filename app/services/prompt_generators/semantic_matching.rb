require "json"

module PromptGenerators
  class SemanticMatching
    def initialize(source_controls:, extracted_controls:)
      @controls_json = JSON.pretty_generate(
        source_controls: source_controls.each_with_index.map do |s, i|
          {
            source_row_index: i,
            control_ids: s.control_ids,
            normalised_control_text: s.normalised_control_text
          }
        end,
        extracted_controls: extracted_controls.map do |e|
          {
            control_id: e.control_id,
            control_text: e.control_text
          }
        end
      )
    end

    def generate
      <<~PROMPT.strip
        You are a security compliance normalization engine.

        Your task is to compare **framework source controls** (from the `source_controls` list) against **trust-center extracted controls** (from the `extracted_controls` list) and determine semantic coverage.

        Each source row has `source_row_index` (0-based position in the list), `control_ids` (labels for that row only), and `normalised_control_text` (the wording to match on). Each extracted item has `control_id` and `control_text`.

        Definitions:

        - FULL match:
        The mapped source row's text fully satisfies the intent and scope of the mapped extracted control(s).

        - PARTIAL match:
        The mapping only partially satisfies intent, is narrower in scope, or is missing important conditions.

        Important Instructions:

        - Decide matches using **semantic meaning of the texts** (`normalised_control_text` vs `control_text`), NOT by sharing control IDs across rows.
        - Each mapping row must refer to **exactly one** source row: set `source_row_index` to that row's index from the input.
        - If one extracted control matches two different source rows, output **two** mapping objects (same `normalized_common_control_ids`, different `source_row_index` and rationale as appropriate).
        - Copy `source_normalised_control_text` **verbatim** from the matched row's `normalised_control_text` (for validation).
        - `normalized_common_control_ids` must list `control_id` values taken exactly from the input `extracted_controls[].control_id`.
        - Administrative access and privileged access may be semantically equivalent.
        - Consider synonyms and paraphrases.
        - Return concise rationales.

        Return ONLY valid JSON.
        Do not include markdown.
        Do not include explanations outside JSON.

        Expected JSON format:

        {
        "mappings": [
            {
            "source_row_index": 0,
            "source_normalised_control_text": "",
            "normalized_common_control_ids": [],
            "match_type": "full|partial",
            "rationale": ""
            }
        ],
        "unmatched_source_controls": [],
        "unmatched_normalized_controls": []
        }

        Input JSON:

        #{@controls_json}
      PROMPT
    end
  end
end
