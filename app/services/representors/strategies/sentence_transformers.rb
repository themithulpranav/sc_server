# frozen_string_literal: true

require "json"
require "open3"

module Representors
  module Strategies
    class SentenceTransformers
      SCRIPT_PATH = Rails.root.join("scripts", "embed_texts.py").freeze

      # Returns a hash with string/symbol keys usable by callers: :model, :dim,
      # :source_embeddings, :pdf_extracted_embeddings, :url_extracted_embeddings
      def embed_control_corpus(source_texts:, pdf_extracted_texts:, url_extracted_texts:)
        src = Array(source_texts).map(&:to_s)
        pdf = Array(pdf_extracted_texts).map(&:to_s)
        url = Array(url_extracted_texts).map(&:to_s)

        if src.empty? && pdf.empty? && url.empty?
          return {
            model: "all-MiniLM-L6-v2",
            dim: 384,
            source_embeddings: [],
            pdf_extracted_embeddings: [],
            url_extracted_embeddings: []
          }
        end

        payload = {
          "source_texts" => src,
          "pdf_extracted_texts" => pdf,
          "url_extracted_texts" => url
        }

        stdout, stderr, status = run_python(JSON.generate(payload))
        unless status.success?
          raise "Embedding script failed (exit #{status.exitstatus}): #{stderr.strip.presence || 'no stderr'}"
        end

        parsed =
          begin
            JSON.parse(stdout, symbolize_names: true)
          rescue JSON::ParserError => e
            snippet = stderr.to_s.strip.presence || stdout.to_s[0, 400]
            raise "Embedding script returned invalid JSON (#{e.message}). stderr/stdout: #{snippet}"
          end
        validate_response!(parsed, src.length, pdf.length, url.length)
        parsed
      end

      private

      def run_python(stdin_data)
        Open3.popen3("python3", SCRIPT_PATH.to_s) do |stdin, stdout, stderr, wait_thr|
          stdin.binmode
          stdin.write(stdin_data)
          stdin.close_write
          out = stdout.read
          err = stderr.read
          [out, err, wait_thr.value]
        end
      end

      def validate_response!(h, src_n, pdf_n, url_n)
        %i[
          source_embeddings
          pdf_extracted_embeddings
          url_extracted_embeddings
        ].each do |key|
          raise "Embedding response missing #{key}" unless h[key].is_a?(Array)
        end

        unless h[:source_embeddings].length == src_n
          raise "source_embeddings length #{h[:source_embeddings].length} != #{src_n}"
        end

        unless h[:pdf_extracted_embeddings].length == pdf_n
          raise "pdf_extracted_embeddings length #{h[:pdf_extracted_embeddings].length} != #{pdf_n}"
        end

        unless h[:url_extracted_embeddings].length == url_n
          raise "url_extracted_embeddings length #{h[:url_extracted_embeddings].length} != #{url_n}"
        end

        dim = h[:dim]
        raise "Embedding response missing dim" unless dim.is_a?(Integer) && dim.positive?

        h[:source_embeddings].each_with_index do |vec, i|
          raise "source_embeddings[#{i}] not an array of length #{dim}" unless vec.is_a?(Array) && vec.length == dim
        end
        h[:pdf_extracted_embeddings].each_with_index do |vec, i|
          raise "pdf_extracted_embeddings[#{i}] invalid" unless vec.is_a?(Array) && vec.length == dim
        end
        h[:url_extracted_embeddings].each_with_index do |vec, i|
          raise "url_extracted_embeddings[#{i}] invalid" unless vec.is_a?(Array) && vec.length == dim
        end
      end
    end
  end
end
