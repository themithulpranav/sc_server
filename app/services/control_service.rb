require "csv"
require "set"

class ControlService
  USE_LLM_FILE_CACHE = false
  CANDIDATE_RETRIEVAL_CONFIG = { strategy: :top_k, k: 4 }.freeze

  def initialize(source_control_csv:, trust_pdf_doc:, trust_center_url:)
    @csv_file = source_control_csv
    @pdf_file = trust_pdf_doc
    @url = trust_center_url
  end

  def call
    sources = parse_source_controls
    pdf_extracted = extract_pdf_controls
    url_extracted = extract_url_controls

    embeddings = run_embeddings_pass(sources, pdf_extracted, url_extracted)
    similarity = (run_similarity_pass(embeddings) if embeddings)
    candidates = (run_candidate_retrieval_pass(similarity) if similarity)

    pdf_mappings = semantic_map(sources, pdf_extracted, candidates&.dig(:pdf_candidates), map_kind: "PNC")
    url_mappings = semantic_map(sources, url_extracted, candidates&.dig(:url_candidates), map_kind: "UNC")

    {
      source_controls: sources.map(&:to_h),
      pdf_extracted_controls: pdf_extracted.map(&:to_h),
      url_extracted_controls: url_extracted.map(&:to_h),
      pdf_control_mappings: pdf_mappings,
      url_control_mappings: url_mappings
    }
  end

  private

  def log(msg)
    Rails.logger.info("[ControlService] #{msg}")
  end

  def run_embeddings_pass(sources, pdf_extracted, url_extracted)
    source_texts = sources.map(&:normalised_control_text)
    pdf_texts = pdf_extracted.map(&:control_text)
    url_texts = url_extracted.map(&:control_text)

    if source_texts.empty? && pdf_texts.empty? && url_texts.empty?
      log("[embeddings] skip: no source or extracted texts")
      return nil
    end

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Representors::Factory.build.embed_control_corpus(
      source_texts: source_texts,
      pdf_extracted_texts: pdf_texts,
      url_extracted_texts: url_texts
    )
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
    log(
      "[embeddings] model=#{result[:model]} dim=#{result[:dim]} " \
      "src=#{source_texts.size} pdf=#{pdf_texts.size} url=#{url_texts.size} elapsed_ms=#{elapsed_ms}" \
      "result=#{result.inspect}"
    )
    result
  end

  def run_similarity_pass(embeddings)
    source_embs = Array(embeddings[:source_embeddings])
    pdf_embs = Array(embeddings[:pdf_extracted_embeddings])
    url_embs = Array(embeddings[:url_extracted_embeddings])

    if source_embs.empty? || (pdf_embs.empty? && url_embs.empty?)
      log(
        "[similarity] skip: source=#{source_embs.size} pdf=#{pdf_embs.size} url=#{url_embs.size}"
      )
      return nil
    end

    strategy = SimilarityScoring::Factory.build(:cosine)

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pdf_scores = strategy.score(source_embeddings: source_embs, target_embeddings: pdf_embs)
    url_scores = strategy.score(source_embeddings: source_embs, target_embeddings: url_embs)
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)

    log(
      "[similarity] strategy=cosine " \
      "pdf_shape=#{matrix_shape(pdf_scores)} url_shape=#{matrix_shape(url_scores)} " \
      "pdf_sample=#{matrix_sample(pdf_scores)} url_sample=#{matrix_sample(url_scores)} " \
      "elapsed_ms=#{elapsed_ms}"
    )

    { pdf_scores: pdf_scores, url_scores: url_scores }
  end

  def run_candidate_retrieval_pass(similarity)
    return nil if similarity.nil?

    pdf_scores = Array(similarity[:pdf_scores])
    url_scores = Array(similarity[:url_scores])

    strategy = CandidateRetrieval::Factory.build(**CANDIDATE_RETRIEVAL_CONFIG)

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pdf_candidates = strategy.select(scores: pdf_scores)
    url_candidates = strategy.select(scores: url_scores)
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)

    log(
      "[retrieval] config=#{CANDIDATE_RETRIEVAL_CONFIG.inspect} " \
      "pdf_sources=#{pdf_candidates.size} pdf_total=#{pdf_candidates.sum(&:size)} " \
      "url_sources=#{url_candidates.size} url_total=#{url_candidates.sum(&:size)} " \
      "pdf_sample=#{candidates_sample(pdf_candidates)} url_sample=#{candidates_sample(url_candidates)} " \
      "elapsed_ms=#{elapsed_ms}"
    )

    { pdf_candidates: pdf_candidates, url_candidates: url_candidates }
  end

  def candidates_sample(candidates)
    return "[]" if candidates.empty?

    candidates.first.inspect
  end

  def matrix_shape(matrix)
    rows = matrix.length
    cols = rows.zero? ? 0 : matrix.first.length
    "#{rows}x#{cols}"
  end

  def matrix_sample(matrix)
    return "[]" if matrix.empty?

    matrix.inspect
  end

  def parse_source_controls
    parsed = csv_rows.map { |row| build_source_control(row) }
    log("parsed #{parsed.length} source controls: #{parsed.map(&:to_h).inspect}")
    parsed
  end

  def csv_rows
    body = csv_body
    log("CSV raw body (#{body.length} chars):\n#{body}")
    CSV.parse(body, headers: true)
  end

  def csv_body
    @csv_file.rewind if @csv_file.respond_to?(:rewind)
    @csv_file.read
  end

  def build_source_control(row)
    SourceControl.new(
      normalised_control_text: row["Control Description"].to_s.strip,
      control_ids: split_control_ids(row["Control ID"])
    )
  end

  def split_control_ids(cell)
    cell.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def extract_pdf_controls
    if @pdf_file.blank?
      log("[pdf] skip: no trust_pdf_doc provided")
      return []
    end

    name = @pdf_file.try(:original_filename) || @pdf_file.inspect
    log("[pdf] entry, file=#{name}")
    extract_and_label(input: @pdf_file, type: :pdf, prefix: "PNC")
  end

  def extract_url_controls
    if @url.blank?
      log("[url] skip: no trust_center_url provided")
      return []
    end

    log("[url] entry, url=#{@url}")
    extract_and_label(input: @url, type: :url, prefix: "UNC")
  end

  def extract_and_label(input:, type:, prefix:)
    texts = ai_extract_controls(input: input, type: type)
    log("[#{type}] normalized control texts: #{texts.inspect}")

    controls = label_extracted_controls(texts, prefix: prefix)
    log("[#{type}] labelled controls: #{controls.map(&:to_h).inspect}")
    controls
  end

  def ai_extract_controls(input:, type:)
    text = TextExtractor::Factory.build(type, input).call
    log("[#{type}] extracted text (#{text.length} chars):\n#{text}")

    # pp text
    # return []

    prompt = PromptGenerators::ExtractControl.new(text).generate
    log("[#{type}] generated prompt:\n#{prompt}")

    log("[#{type}] hitting OpenRouter::Chat...")
    payload = llm_chat(prompt, extract_llm_cache_key(input: input, type: type))
    log("[#{type}] AI parsed payload: #{payload.inspect}")

    normalize_control_texts(payload)
  end

  def normalize_control_texts(payload)
    list = payload["controls"] || payload[:controls]
    Array(list).map(&:to_s).reject(&:blank?)
  end

  def label_extracted_controls(texts, prefix:)
    texts.each_with_index.map do |text, i|
      ExtractedControl.new(control_id: "#{prefix} #{i + 1}", control_text: text)
    end
  end

  def semantic_map(source_controls, extracted_controls, candidates, map_kind:)
    if source_controls.empty? || extracted_controls.empty?
      log(
        "[semantic_map][#{map_kind}] skip LLM: " \
        "source_empty=#{source_controls.empty?} extracted_empty=#{extracted_controls.empty?}"
      )
      return empty_mapping_payload(source_controls, extracted_controls)
    end

    cands = Array(candidates)
    if cands.empty? || cands.all? { |row| Array(row).empty? }
      log("[semantic_map][#{map_kind}] skip LLM: no candidates for any source")
      return empty_mapping_payload(source_controls, extracted_controls)
    end

    sources_with_candidates = cands.count { |row| Array(row).any? }
    total_candidates = cands.sum { |row| Array(row).size }

    prompt = PromptGenerators::CandidateMatching.new(
      source_controls: source_controls,
      extracted_controls: extracted_controls,
      candidates: cands
    ).generate
    log(
      "[semantic_map][#{map_kind}] generated prompt chars=#{prompt.length} " \
      "sources_with_candidates=#{sources_with_candidates} total_candidates=#{total_candidates}"
    )

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raw = llm_chat(prompt, semantic_llm_cache_key(map_kind))
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
    log("[semantic_map][#{map_kind}] AI mapping payload: #{raw.inspect} elapsed_ms=#{elapsed_ms}")

    mappings = normalize_mappings(
      raw["mappings"] || raw[:mappings],
      source_controls
    )
    mappings = drop_hallucinated_candidates(
      mappings, source_controls, extracted_controls, cands, map_kind: map_kind
    )
    enrich_unmatched(mappings, source_controls, extracted_controls)
  end

  def llm_chat(prompt, cache_key)
    OpenRouter::Chat.call(prompt, cache_key: USE_LLM_FILE_CACHE ? cache_key : nil)
  end

  def extract_llm_cache_key(input:, type:)
    case type
    when :pdf
      "extract1-pdf-#{input.try(:original_filename).presence || "pdf"}"
    when :url
      "extract1-url-#{input.to_s.strip}"
    else
      "extract1-#{type}"
    end
  end

  def csv_cache_label
    @csv_file.try(:original_filename).presence || "csv"
  end

  def semantic_llm_cache_key(map_kind)
    "semantic-candidates-#{map_kind}-#{csv_cache_label}"
  end

  def empty_mapping_payload(source_controls, extracted_controls)
    {
      mappings: [],
      unmatched_source_controls: source_rows_to_unmatched(source_controls),
      unmatched_normalized_controls: extracted_rows_to_unmatched(extracted_controls)
    }
  end

  def normalize_mappings(list, source_controls)
    Array(list).map { |row| normalize_mapping_row(row, source_controls) }
  end

  def normalize_mapping_row(row, source_controls)
    h = row.is_a?(Hash) ? row.transform_keys(&:to_s) : {}
    ext = Array(h["normalized_common_control_ids"]).map(&:to_s).reject(&:blank?)

    valid_idx = parse_source_row_index(h["source_row_index"], source_controls.length)

    src =
      if valid_idx
        source_controls[valid_idx].control_ids.map(&:to_s)
      else
        Array(h["source_control_ids"]).map(&:to_s).reject(&:blank?)
      end

    if valid_idx
      verify_mapping_source_text(
        valid_idx,
        h["source_normalised_control_text"],
        source_controls[valid_idx].normalised_control_text
      )
    end

    {
      source_row_index: valid_idx,
      source_control_ids: src,
      normalized_common_control_ids: ext,
      match_type: normalize_match_type(h["match_type"]),
      rationale: h["rationale"].to_s
    }
  end

  def parse_source_row_index(raw, source_count)
    return nil if source_count <= 0

    i = Integer(raw)
    return nil if i < 0 || i >= source_count

    i
  rescue ArgumentError, TypeError
    nil
  end

  def verify_mapping_source_text(idx, stated, expected)
    stated = stated.to_s.strip
    return if stated.blank?

    if collapse_ws(stated) != collapse_ws(expected.to_s)
      log(
        "[semantic_map] source_normalised_control_text mismatch at index #{idx} " \
        "(stated length=#{stated.length})"
      )
    end
  end

  def collapse_ws(s)
    s.gsub(/\s+/, " ").strip
  end

  def normalize_match_type(raw)
    s = raw.to_s.strip.downcase
    return s if %w[full partial].include?(s)

    log("[semantic_map] unknown match_type #{raw.inspect}, coercing to partial")
    "partial"
  end

  def drop_hallucinated_candidates(mappings, source_controls, extracted_controls, candidates, map_kind:)
    allowed_per_source = candidates.map do |row|
      Array(row).map { |c| extracted_controls[c[:target_index]]&.control_id }.compact.to_set
    end

    mappings.map do |m|
      idx = m[:source_row_index]
      unless idx.is_a?(Integer) && idx >= 0 && idx < source_controls.length
        log("[semantic_map][#{map_kind}] dropping mapping with invalid source_row_index=#{idx.inspect}")
        next nil
      end

      allowed   = allowed_per_source[idx] || Set.new
      raw_ids   = Array(m[:normalized_common_control_ids])
      valid_ids = raw_ids.select { |id| allowed.include?(id) }
      dropped   = raw_ids - valid_ids

      if dropped.any?
        log(
          "[semantic_map][#{map_kind}] dropping hallucinated ids " \
          "#{dropped.inspect} for source_row_index=#{idx}"
        )
      end

      if valid_ids.empty?
        log("[semantic_map][#{map_kind}] dropping mapping for source_row_index=#{idx}: no valid ids after filtering")
        next nil
      end

      m.merge(normalized_common_control_ids: valid_ids)
    end.compact
  end

  def enrich_unmatched(mappings, source_controls, extracted_controls)
    matched_indices = Set.new
    legacy_matched_ids = Set.new

    mappings.each do |m|
      idx = m[:source_row_index]
      if idx.is_a?(Integer) && idx >= 0 && idx < source_controls.length
        matched_indices << idx
      else
        Array(m[:source_control_ids]).each { |id| legacy_matched_ids << id.to_s }
      end
    end

    matched_extracted = mappings.each_with_object(Set.new) do |m, acc|
      m[:normalized_common_control_ids].each { |id| acc << id }
    end

    unmatched_sources = source_controls.each_with_index.reject do |s, i|
      matched_indices.include?(i) ||
        s.control_ids.any? { |id| legacy_matched_ids.include?(id.to_s) }
    end.map(&:first)

    unmatched_extracted = extracted_controls.reject do |e|
      matched_extracted.include?(e.control_id)
    end

    {
      mappings: mappings,
      unmatched_source_controls: source_rows_to_unmatched(unmatched_sources),
      unmatched_normalized_controls: extracted_rows_to_unmatched(unmatched_extracted)
    }
  end

  def source_rows_to_unmatched(rows)
    rows.map do |s|
      {
        control_ids: s.control_ids,
        normalised_control_text: s.normalised_control_text
      }
    end
  end

  def extracted_rows_to_unmatched(rows)
    rows.map do |e|
      {
        control_id: e.control_id,
        control_text: e.control_text
      }
    end
  end
end
