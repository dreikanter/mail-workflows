# frozen_string_literal: true

require "mail"
require "reverse_markdown"
require "yaml"
require "digest"
require "cgi"
require "fileutils"
require "time"
require_relative "slug"

module MailWorkflows
  # Converts raw .eml files into LLM-ready markdown with YAML frontmatter
  # and extracts attachments to a separate directory.
  class Normalizer
    def initialize(home)
      @home = home
    end

    # Normalize a single .eml file.
    # Returns the output .md path on success, nil if skipped (already normalized).
    def normalize(eml_path, account:, folder:)
      msg = Mail.read(eml_path)
      message_id = msg.message_id || Digest::SHA256.hexdigest(File.read(eml_path))

      return nil if already_normalized?(account, message_id)

      stem = build_stem(msg, account)
      filenames = extract_attachments(msg, stem)
      md_path = write_markdown(msg, stem, account, folder, message_id, filenames)
      md_path
    end

    private

    def normalized_dir(account)
      File.join(@home, "normalized", account)
    end

    def attachments_dir
      File.join(@home, "attachments")
    end

    def already_normalized?(account, message_id)
      base = normalized_dir(account)
      %w[new processed].each do |subdir|
        dir = File.join(base, subdir)
        next unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*.md")).each do |md_file|
          content = File.read(md_file)
          if content.match?(/^message_id:\s.*#{Regexp.escape(message_id)}/)
            return true
          end
        end
      end
      false
    end

    def build_stem(msg, account)
      date = extract_date(msg)
      timestamp = date.strftime("%Y%m%d-%H%M%S")
      slug = Slug.slugify(msg.subject)
      base_stem = "#{timestamp}_#{slug}"

      # Check for collision and add suffix if needed
      out_dir = File.join(normalized_dir(account), "new")
      if collision?(out_dir, base_stem, account)
        mid = msg.message_id || ""
        suffix = Digest::SHA256.hexdigest(mid)[0, 8]
        "#{base_stem}_#{suffix}"
      else
        base_stem
      end
    end

    def collision?(out_dir, base_stem, account)
      return true if File.exist?(File.join(out_dir, "#{base_stem}.md"))

      processed_dir = File.join(normalized_dir(account), "processed")
      return true if File.exist?(File.join(processed_dir, "#{base_stem}.md"))

      false
    end

    def extract_date(msg)
      msg.date&.to_time || Time.now
    rescue ArgumentError
      Time.now
    end

    def write_markdown(msg, stem, account, folder, message_id, attachment_filenames)
      out_dir = File.join(normalized_dir(account), "new")
      FileUtils.mkdir_p(out_dir)

      frontmatter = build_frontmatter(msg, folder, message_id, attachment_filenames)
      body = extract_body(msg)

      md_path = File.join(out_dir, "#{stem}.md")
      File.write(md_path, "#{frontmatter}\n#{body}\n")
      md_path
    end

    def build_frontmatter(msg, folder, message_id, attachment_filenames)
      data = {
        "message_id" => message_id,
        "from" => format_address(msg[:from]),
        "to" => format_address(msg[:to]),
        "subject" => msg.subject || "",
        "date" => extract_date(msg).iso8601,
        "folder" => folder
      }

      data["attachments"] = attachment_filenames unless attachment_filenames.empty?

      "---\n#{YAML.dump(data).sub(/\A---\n/, "")}---\n"
    end

    def format_address(field)
      return "" if field.nil?

      field.to_s
    end

    def extract_body(msg)
      text = extract_text_part(msg)
      return "" if text.nil? || text.strip.empty?

      text = force_utf8(text)
      strip_signature(text).strip
    end

    def extract_text_part(msg)
      if msg.multipart?
        # Prefer text/plain
        plain = msg.text_part
        return plain.decoded if plain

        # Fall back to text/html -> markdown
        html = msg.html_part
        return html_to_markdown(html.decoded) if html

        # Try first text part
        msg.parts.each do |part|
          return part.decoded if part.content_type&.start_with?("text/plain")
          return html_to_markdown(part.decoded) if part.content_type&.start_with?("text/html")
        end
        nil
      elsif msg.content_type&.start_with?("text/html")
        html_to_markdown(msg.decoded)
      else
        msg.decoded
      end
    rescue Mail::UnknownEncodingType, Encoding::UndefinedConversionError
      # Fallback: try body raw value
      msg.body.to_s
    end

    def html_to_markdown(html)
      ReverseMarkdown.convert(html, unknown_tags: :bypass).strip
    end

    def force_utf8(text)
      text.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    end

    def strip_signature(text)
      # Strip common email signature delimiter
      text.sub(/\n-- \n.*\z/m, "")
    end

    def all_attachments(msg)
      return [] unless msg.multipart?

      msg.parts.select { |p| p.attachment? || inline_image?(p) }
    end

    def inline_image?(part)
      return false unless part.content_type&.start_with?("image/")

      disposition = part.content_disposition
      disposition.nil? || disposition.start_with?("inline")
    end

    def attachment_filename(attachment)
      name = attachment.filename || "attachment"
      # Decode percent-encoded characters (e.g., %2b → +) common in MIME
      # filenames. Protect literal "+" first since CGI.unescape treats it
      # as space (HTML form convention), but in filenames "+" is literal.
      CGI.unescape(name.gsub("+", "%2B"))
    end

    def extract_attachments(msg, stem)
      attachments = all_attachments(msg)
      return [] if attachments.empty?

      out_dir = File.join(attachments_dir, stem)
      FileUtils.mkdir_p(out_dir)

      filenames = []
      name_counts = Hash.new(0)
      attachments.each do |att|
        name = attachment_filename(att)
        name_counts[name] += 1
        name = deduplicate_filename(name, name_counts[name]) if name_counts[name] > 1

        File.binwrite(File.join(out_dir, name), att.decoded)
        filenames << name
      end
      filenames
    end

    def deduplicate_filename(name, count)
      ext = File.extname(name)
      base = File.basename(name, ext)
      "#{base}-#{count}#{ext}"
    end
  end
end
