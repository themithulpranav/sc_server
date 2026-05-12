require "json"

module PromptGenerators
  class CandidateMatching
    SCORE_PRECISION = 3

    def initialize(source_controls:, extracted_controls:, candidates:)
      extracted_by_index = extracted_controls.each_with_index.to_h { |e, j| [j, e] }
      cands_by_source = Array(candidates)

      referenced_ids = {}
      blocks = []

      source_controls.each_with_index do |s, i|
        cand_refs = []

        Array(cands_by_source[i]).each do |c|
          ext = extracted_by_index[c[:target_index]]
          next unless ext

          referenced_ids[ext.control_id] = true
          cand_refs << {
            control_id: ext.control_id,
            similarity: c[:score].to_f.round(SCORE_PRECISION)
          }
        end

        next if cand_refs.empty?

        blocks << {
          source_row_index: i,
          control_ids: s.control_ids,
          normalised_control_text: s.normalised_control_text,
          candidates: cand_refs
        }
      end

      dict = {}
      extracted_controls.each do |e|
        dict[e.control_id] = e.control_text if referenced_ids.key?(e.control_id)
      end

      @input_json = JSON.pretty_generate(
        extracted_controls: dict,
        sources: blocks
      )
    end

    def generate
      <<~PROMPT.strip
        You are a security compliance normalization engine.

        Your task is to compare **framework source controls** against a pre-selected shortlist of **trust-center extracted controls** (the `candidates` list inside each source block) and determine semantic coverage.

        Each source block has `source_row_index` (0-based position from the upstream list), `control_ids` (labels for that row only), `normalised_control_text` (the wording to match on), and `candidates` (the only extracted controls eligible for this source). Each candidate carries `control_id` and `similarity` (a 0..1 cosine-similarity hint over precomputed text embeddings).

        The **full text of each extracted control** is stored once in the top-level `extracted_controls` object, keyed by `control_id`. To compare a candidate against a source, look up `extracted_controls[candidate.control_id]` to obtain its `control_text`.

        Definitions:

        - FULL match:
        The source row's text fully satisfies the intent and scope of the candidate extracted control.

        - PARTIAL match:
        The mapping only partially satisfies intent, is narrower in scope, or is missing important conditions.

        Important Instructions:

        - Decide matches using **semantic meaning of the texts** (`normalised_control_text` vs. the looked-up `extracted_controls[candidate.control_id]`). Treat `similarity` as a soft hint only; a high similarity does NOT guarantee a real match, and a lower similarity does NOT preclude one.
        - `normalized_common_control_ids` for a mapping MUST be a subset of that source's own `candidates[].control_id` values. Do not invent IDs or borrow IDs from other sources' candidate lists.
        - Output one mapping object per matched candidate for a given source. You may output zero, one, or several mappings per source.
        - Set `source_row_index` exactly to the value provided in the source block.
        - Copy `source_normalised_control_text` **verbatim** from the matched source block's `normalised_control_text` (for validation).
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
        ]
        }

        Input JSON:

        #{@input_json}
      PROMPT
    end
  end
end
