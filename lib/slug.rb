# frozen_string_literal: true

require "babosa"

module MailWorkflows
  # Converts email subjects into filesystem-safe slug strings.
  # Uses babosa gem for transliteration (Latin diacritics, Cyrillic, etc.).
  module Slug
    module_function

    # Convert a subject string to a filesystem-safe slug.
    # Returns "no-subject" for empty/whitespace-only input.
    def slugify(text)
      return "no-subject" if text.nil? || text.strip.empty?

      result = text.to_slug.transliterate(:cyrillic).normalize.to_s
      # Strip any remaining non-ASCII characters (CJK, Arabic, etc.)
      result = result.gsub(/[^a-z0-9-]/, "").gsub(/-{2,}/, "-").sub(/\A-|-\z/, "")
      return "no-subject" if result.empty?

      truncate(result, 60)
    end

    # Truncate string at approximately max_length on a word boundary.
    def truncate(text, max_length)
      return text if text.length <= max_length

      truncated = text[0, max_length]
      # Cut at last hyphen to avoid partial words
      last_sep = truncated.rindex("-")
      truncated = truncated[0, last_sep] if last_sep && last_sep > max_length / 2
      truncated.sub(/-\z/, "")
    end
  end
end
