# frozen_string_literal: true

require "yaml"
require "json"
require "fileutils"
require "time"
require_relative "log"
require_relative "slug"
require_relative "rule_set"
require_relative "handler"
require_relative "notifier"

module MailWorkflows
  # Processes normalized emails against rules: matches, runs handlers,
  # saves output, sends notifications, and manages file lifecycle.
  class Processor
    MAX_RETRIES = 3

    def initialize(home, logger: NULL_LOGGER)
      @home = home
      @logger = logger
      @rule_set = RuleSet.new(home, logger: logger)
    end

    # Process all pending normalized emails across all accounts.
    # Returns counts: {processed:, matched:, failed:, errors:}
    def run
      counts = { processed: 0, matched: 0, failed: 0, errors: 0 }

      each_pending_email do |md_path, account|
        process_email(md_path, account, counts)
      rescue StandardError => e
        counts[:errors] += 1
        @logger.error "processor error #{File.basename(md_path)}: #{e.message}"
        @logger.error e.backtrace&.first(5)&.join("\n")
      end

      @logger.info "processor done: #{counts[:matched]} matched, " \
                   "#{counts[:processed]} processed (no match), " \
                   "#{counts[:failed]} failed, #{counts[:errors]} errors"
      counts
    end

    private

    def each_pending_email
      normalized_dir = File.join(@home, "normalized")
      return unless Dir.exist?(normalized_dir)

      Dir.glob(File.join(normalized_dir, "*")).sort.each do |account_dir|
        next unless File.directory?(account_dir)

        account = File.basename(account_dir)
        new_dir = File.join(account_dir, "new")
        next unless Dir.exist?(new_dir)

        Dir.glob(File.join(new_dir, "*.md")).sort.each do |md_path|
          yield md_path, account
        end
      end
    end

    def process_email(md_path, account, counts)
      frontmatter, body = parse_normalized(md_path)
      rule = @rule_set.match(frontmatter, body)

      unless rule
        move_to_processed(md_path, account)
        counts[:processed] += 1
        @logger.info "no rule matched: #{File.basename(md_path)}"
        return
      end

      retries = read_retries(md_path)
      if retries >= MAX_RETRIES
        move_to_failed(md_path, account)
        cleanup_retries(md_path)
        counts[:failed] += 1
        @logger.warn "max retries reached, moving to failed: #{File.basename(md_path)}"
        return
      end

      input = build_handler_input(frontmatter, body, rule, md_path)

      begin
        output = Handler.execute(rule, input, home: @home, logger: @logger)
      rescue StandardError => e
        increment_retries(md_path, retries)
        @logger.error "handler failed for #{File.basename(md_path)}: #{e.message}"
        @logger.error e.backtrace&.first(5)&.join("\n")
        counts[:errors] += 1
        return
      end

      save_output(rule, frontmatter, output)
      send_notifications(rule, output, frontmatter)
      move_to_processed(md_path, account)
      cleanup_retries(md_path)
      counts[:matched] += 1
      @logger.info "handled: #{File.basename(md_path)} → #{rule.name}"
    end

    def parse_normalized(md_path)
      content = File.read(md_path)
      # Split YAML frontmatter from body
      match = content.match(/\A---\n(.*?)^---\n(.*)\z/m)
      raise "invalid normalized email format: #{md_path}" unless match

      frontmatter = YAML.safe_load(match[1]) || {}
      body = match[2].strip
      [frontmatter, body]
    end

    def build_handler_input(frontmatter, body, rule, md_path)
      stem = File.basename(md_path, ".md")
      attachment_dir = File.join(@home, "attachments", stem)
      state_dir = File.join(@home, "state", rule.name)
      FileUtils.mkdir_p(state_dir)

      {
        "email" => {
          "message_id" => frontmatter["message_id"],
          "from" => frontmatter["from"],
          "to" => frontmatter["to"],
          "subject" => frontmatter["subject"],
          "date" => frontmatter["date"],
          "folder" => frontmatter["folder"],
          "body" => body,
          "attachments" => frontmatter.fetch("attachments", []),
          "attachment_dir" => Dir.exist?(attachment_dir) ? attachment_dir : nil
        },
        "preprocessed" => load_preprocessed(attachment_dir),
        "state_dir" => state_dir,
        "config" => rule.handler.reject { |k, _| %w[type command prompt].include?(k) }
      }
    end

    def load_preprocessed(attachment_dir)
      return {} unless Dir.exist?(attachment_dir)

      preprocessed = {}
      Dir.glob(File.join(attachment_dir, "*.md")).each do |md_file|
        # e.g., statement.pdf.md → statement.pdf
        original = File.basename(md_file).sub(/\.md\z/, "")
        preprocessed[original] = File.read(md_file)
      end
      preprocessed
    end

    def save_output(rule, frontmatter, output)
      state_dir = File.join(@home, "state", rule.name)
      FileUtils.mkdir_p(state_dir)

      timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
      slug = Slug.slugify(frontmatter["subject"])
      filename = "#{timestamp}_#{slug}.json"

      path = File.join(state_dir, filename)
      File.write(path, JSON.pretty_generate(output))
      @logger.info "saved output: #{path}"
    end

    def send_notifications(rule, output, frontmatter)
      metadata = {
        from: frontmatter["from"],
        subject: frontmatter["subject"],
        date: frontmatter["date"],
        rule_name: rule.name
      }

      rule.notify.each do |notify_config|
        Notifier.send(notify_config, output, metadata, home: @home, logger: @logger)
      rescue StandardError => e
        @logger.error "notification failed (#{notify_config["type"]}): #{e.message}"
      end
    end

    def move_to_processed(md_path, account)
      dest_dir = File.join(@home, "normalized", account, "processed")
      FileUtils.mkdir_p(dest_dir)
      dest = File.join(dest_dir, File.basename(md_path))
      File.rename(md_path, dest)
    end

    def move_to_failed(md_path, account)
      dest_dir = File.join(@home, "normalized", account, "failed")
      FileUtils.mkdir_p(dest_dir)
      dest = File.join(dest_dir, File.basename(md_path))
      File.rename(md_path, dest)
    end

    # --- Retry tracking ---

    def retries_path(md_path)
      "#{md_path}.retries"
    end

    def read_retries(md_path)
      path = retries_path(md_path)
      return 0 unless File.exist?(path)

      File.read(path).strip.to_i
    end

    def increment_retries(md_path, current)
      File.write(retries_path(md_path), (current + 1).to_s)
    end

    def cleanup_retries(md_path)
      path = retries_path(md_path)
      File.delete(path) if File.exist?(path)
    end
  end
end
