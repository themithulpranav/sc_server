require "csv"
require "set"

class ControlService
  USE_LLM_FILE_CACHE = false

  def initialize(source_control_csv:, trust_pdf_doc:, trust_center_url:)
    @csv_file = source_control_csv
    @pdf_file = trust_pdf_doc
    @url = trust_center_url
  end

  def call
    sources = parse_source_controls
    pdf_extracted = extract_pdf_controls
    url_extracted = extract_url_controls

    {
      source_controls: sources.map(&:to_h),
      pdf_extracted_controls: pdf_extracted.map(&:to_h),
      url_extracted_controls: url_extracted.map(&:to_h),
      pdf_control_mappings: semantic_map(sources, pdf_extracted, map_kind: "PNC"),
      url_control_mappings: semantic_map(sources, url_extracted, map_kind: "UNC")
    }
  end

  private

  def log(msg)
    Rails.logger.info("[ControlService] #{msg}")
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

  def semantic_map(source_controls, extracted_controls, map_kind:)
    if source_controls.empty? || extracted_controls.empty?
      log("[semantic_map] skip LLM: source_empty=#{source_controls.empty?} extracted_empty=#{extracted_controls.empty?}")
      return empty_mapping_payload(source_controls, extracted_controls)
    end

    prompt = PromptGenerators::SemanticMatching.new(
      source_controls: source_controls,
      extracted_controls: extracted_controls
    ).generate
    log("[semantic_map] generated prompt (#{prompt.length} chars)")

    raw = llm_chat(prompt, semantic_llm_cache_key(map_kind))
    log("[semantic_map] AI mapping payload: #{raw.inspect}")

    mappings = normalize_mappings(
      raw["mappings"] || raw[:mappings],
      source_controls
    )
    enrich_unmatched(mappings, source_controls, extracted_controls)
  end

  def llm_chat(prompt, cache_key)
    OpenRouter::Chat.call(prompt, cache_key: USE_LLM_FILE_CACHE ? cache_key : nil)
  end

  def extract_llm_cache_key(input:, type:)
    case type
    when :pdf
      "extract-pdf-#{input.try(:original_filename).presence || "pdf"}"
    when :url
      "extract-url-#{input.to_s.strip}"
    else
      "extract-#{type}"
    end
  end

  def csv_cache_label
    @csv_file.try(:original_filename).presence || "csv"
  end

  def semantic_llm_cache_key(map_kind)
    "semantic-#{map_kind}-#{csv_cache_label}"
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
