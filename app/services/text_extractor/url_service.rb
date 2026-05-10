require "playwright"

module TextExtractor
  class UrlService < BaseService
    NAVIGATION_TIMEOUT_MS = 30_000

    CONTROL_KEYWORDS = %w[
      must
      shall
      required
      enforced
      reviewed
      monitored
      authenticated
      authorized
      encrypted
      restricted
      prohibited
      verified
      logged
      approved
      protected
      configured
    ].freeze

    NOISE_PATTERNS = [
      /cookie policy/i,
      /privacy policy/i,
      /terms of service/i,
      /accept cookies/i,
      /all rights reserved/i,
      /sign in/i,
      /log in/i
    ].freeze

    def call
      Rails.logger.info(
        "[TextExtractor::UrlService] launching Playwright for: #{@input}"
      )

      blocks = render_and_extract

      formatted_text = build_ai_input(blocks)

      Rails.logger.info(
        "[TextExtractor::UrlService] extracted #{formatted_text.length} chars from #{@input}"
      )

      formatted_text
    end

    private

    def render_and_extract
      output = []

      Playwright.create(
        playwright_cli_executable_path: cli_path
      ) do |playwright|
        playwright.chromium.launch(
          headless: true,
          executablePath: chromium_path,
          args: [
            "--no-sandbox",
            "--disable-dev-shm-usage"
          ]
        ) do |browser|
          page = browser.new_page

          page.goto(
            target_url,
            waitUntil: "networkidle",
            timeout: NAVIGATION_TIMEOUT_MS
          )

          log_diagnostics(page)

          output = extract_visible_text(page)
        end
      end

      output
    end

    def log_diagnostics(page)
      Rails.logger.info("[UrlService] page url: #{page.url.inspect}")
      Rails.logger.info("[UrlService] page title: #{page.title.inspect}")

      body_len = page.evaluate(
        "() => (document.body && document.body.innerText || '').length"
      )
      Rails.logger.info("[UrlService] body innerText length: #{body_len}")

      body_sample = page.evaluate(
        "() => (document.body && document.body.innerText || '').slice(0, 1500)"
      )
      Rails.logger.info("[UrlService] body sample (first 1500): #{body_sample.inspect}")

      tag_counts = page.evaluate(<<~JS)
        () => {
          const tags = ['h1','h2','h3','h4','h5','h6','p','li','td','th','div','section','article'];
          return Object.fromEntries(tags.map(t => [t, document.querySelectorAll(t).length]));
        }
      JS
      Rails.logger.info("[UrlService] tag counts: #{tag_counts.inspect}")

      noise_hits = page.evaluate(<<~JS)
        () => {
          const sels = ['nav','footer','header','aside','[role="navigation"]','.cookie','.cookies','.banner','.popup','.modal','.sidebar','.menu','.advertisement','.ads'];
          return Object.fromEntries(sels.map(s => [s, document.querySelectorAll(s).length]));
        }
      JS
      Rails.logger.info("[UrlService] noise selector hits: #{noise_hits.inspect}")
    rescue => e
      Rails.logger.warn("[UrlService] diagnostics failed: #{e.class}: #{e.message}")
    end

    def extract_visible_text(page)
      blocks = page.evaluate(<<~JS)
        () => {
          const BLOCK_TAGS = [
            'h1','h2','h3','h4','h5','h6',
            'p',
            'li',
            'td',
            'th'
          ];

          const NOISE_SELECTORS = [
            'nav',
            'footer',
            'header',
            'aside',
            '[role="navigation"]',
            '.cookie',
            '.cookies',
            '.banner',
            '.popup',
            '.modal',
            '.sidebar',
            '.menu',
            '.advertisement',
            '.ads'
          ];

          // Remove noisy elements
          NOISE_SELECTORS.forEach(selector => {
            document.querySelectorAll(selector).forEach(el => el.remove());
          });

          // Prefer semantic content containers
          const root =
            document.querySelector('main') ||
            document.querySelector('article') ||
            document.querySelector('[role="main"]') ||
            document.body;

          const blocks = [];
          let currentSection = [];

          const isVisible = (el) => {
            const style = window.getComputedStyle(el);

            return (
              style &&
              style.display !== 'none' &&
              style.visibility !== 'hidden' &&
              el.offsetParent !== null
            );
          };

          const normalize = (text) => {
            return text
              .replace(/\\s+/g, ' ')
              .trim();
          };

          const controlKeywords = [
            'must',
            'shall',
            'required',
            'enforced',
            'reviewed',
            'monitored',
            'authenticated',
            'authorized',
            'encrypted',
            'restricted',
            'prohibited',
            'verified',
            'logged',
            'approved',
            'protected',
            'configured'
          ];

          // Alpaca table cells: title (bodyRegularPlus) + control text (bodySmallAlt) as siblings; innerText on td merges them.
          const structuredAlpacaControlBody = (cell) => {
            if (!cell || (cell.tagName !== 'TD' && cell.tagName !== 'TH')) return null;

            const titleEl = cell.querySelector('[data-component="Typography"][data-variant="bodyRegularPlus"]');
            const bodyEl = cell.querySelector('[data-component="Typography"][data-variant="bodySmallAlt"]');

            if (!titleEl || !bodyEl) return null;

            const title = normalize(titleEl.innerText || '');
            const body = normalize(bodyEl.innerText || '');

            if (!title || !body) return null;

            return body;
          };

          root.querySelectorAll(BLOCK_TAGS.join(',')).forEach(el => {
            if (!isVisible(el)) return;

            const tableCell = el.tagName === 'P' || el.tagName === 'LI' ? el.closest('td, th') : null;

            if (tableCell && structuredAlpacaControlBody(tableCell) !== null) {
              return;
            }

            if (el.tagName === 'TD' || el.tagName === 'TH') {
              const bodyOnly = structuredAlpacaControlBody(el);

              if (bodyOnly !== null) {
                if (bodyOnly.length < 25) return;

                const lowerBody = bodyOnly.toLowerCase();

                const score = controlKeywords.reduce((acc, keyword) => {
                  return acc + (lowerBody.includes(keyword) ? 1 : 0);
                }, 0);

                blocks.push({
                  type: el.tagName.toLowerCase(),
                  section: [...currentSection],
                  text: bodyOnly,
                  control_candidate_score: score
                });

                return;
              }
            }

            const text = normalize(el.innerText || '');

            // Skip empty/small blocks
            if (!text || text.length < 25) return;

            const lower = text.toLowerCase();

            const score = controlKeywords.reduce((acc, keyword) => {
              return acc + (lower.includes(keyword) ? 1 : 0);
            }, 0);

            // Track headings / sections
            if (/^H[1-6]$/.test(el.tagName)) {
              const level = Number(el.tagName[1]);

              currentSection = currentSection.slice(0, level - 1);
              currentSection[level - 1] = text;

              blocks.push({
                type: 'heading',
                level,
                section: [...currentSection],
                text,
                control_candidate_score: score
              });

              return;
            }

            blocks.push({
              type: el.tagName.toLowerCase(),
              section: [...currentSection],
              text,
              control_candidate_score: score
            });
          });

          // Deduplicate
          const normalizeForDedup = (text) => {
            return text
              .toLowerCase()
              .replace(/[^a-z0-9 ]/g, '')
              .replace(/\s+/g, ' ')
              .trim();
          };

          const seen = new Set();

          return blocks.filter(block => {
            const key = normalizeForDedup(block.text);
          
            if (seen.has(key)) return false;
          
            seen.add(key);
          
            return true;
          });
        }
      JS

      filter_noise(blocks)
    end

    def filter_noise(blocks)
      blocks.reject do |block|
        text = block["text"].to_s.strip

        next true if text.blank?

        NOISE_PATTERNS.any? { |pattern| text.match?(pattern) }
      end
    end

    def build_ai_input(blocks)
      prioritized_blocks = prioritize_blocks(blocks)

      prioritized_blocks.map do |block|
        next if block["type"] == "heading"

        <<~TEXT
      SECTION: #{Array(block["section"]).join(" > ")}
      TEXT: #{block["text"]}
    TEXT
      end.compact.join("\n\n")
    end

    def prioritize_blocks(blocks)
      blocks.sort_by do |block|
        -block["control_candidate_score"].to_i
      end
    end

    def target_url
      @input.to_s
    end

    def cli_path
      ENV.fetch(
        "PLAYWRIGHT_CLI_EXECUTABLE_PATH",
        "playwright"
      )
    end

    def chromium_path
      ENV.fetch(
        "CHROMIUM_EXECUTABLE_PATH",
        "/usr/bin/chromium"
      )
    end
  end
end
