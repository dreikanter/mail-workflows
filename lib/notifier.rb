# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "yaml"
require_relative "log"
require_relative "mailer"

module MailWorkflows
  # Dispatches notifications to the correct notifier type.
  module Notifier
    module_function

    # Sends a notification for a handler result.
    # notify_config is a single entry from the rule's notify array.
    # metadata contains email info (from, subject, date, rule_name).
    def send(notify_config, handler_output, metadata, home:, logger: NULL_LOGGER)
      type = notify_config.fetch("type")

      case type
      when "email"
        EmailNotifier.new(home, logger: logger).notify(notify_config, handler_output, metadata)
      when "telegram"
        TelegramNotifier.new(home, logger: logger).notify(notify_config, handler_output, metadata)
      when "desktop"
        DesktopNotifier.new(logger: logger).notify(handler_output, metadata)
      else
        logger.warn "unknown notifier type: #{type}"
      end
    end
  end

  # Sends handler output via email using the existing Mailer.
  class EmailNotifier
    def initialize(home, logger: NULL_LOGGER)
      @home = home
      @logger = logger
    end

    def notify(config, handler_output, metadata)
      mailer = Mailer.new(@home, logger: @logger)
      to = config["to"] || default_to
      subject = "[#{metadata[:rule_name]}] #{handler_output["summary"]}"

      body = <<~BODY
        Rule: #{metadata[:rule_name]}
        From: #{metadata[:from]}
        Subject: #{metadata[:subject]}
        Date: #{metadata[:date]}

        #{handler_output["summary"]}

        #{handler_output["body"]}
      BODY

      mailer.send(to: to, subject: subject, body: body)
      @logger.info "email notification sent to #{to}"
    end

    private

    def default_to
      config_path = File.join(@home, "accounts.yml")
      yaml = YAML.load_file(config_path, permitted_classes: [Symbol])
      yaml.dig("notifications", "email", "from") || raise("no default email recipient configured")
    end
  end

  # Sends handler summary via Telegram Bot API.
  class TelegramNotifier
    def initialize(home, logger: NULL_LOGGER)
      @home = home
      @logger = logger
      @config = load_config
    end

    def notify(_notify_config, handler_output, metadata)
      text = <<~MSG.chomp
        *#{escape_md(metadata[:rule_name])}*
        From: #{escape_md(metadata[:from])}
        Subject: #{escape_md(metadata[:subject])}

        #{escape_md(handler_output["summary"])}
      MSG

      send_message(text)
      @logger.info "telegram notification sent"
    end

    private

    attr_reader :config

    def load_config
      path = File.join(@home, "accounts.yml")
      yaml = YAML.load_file(path, permitted_classes: [Symbol])
      yaml.dig("notifications", "telegram") || raise("missing notifications.telegram in accounts.yml")
    end

    def send_message(text)
      token = config.fetch("token")
      chat_id = config.fetch("chat_id")
      uri = URI("https://api.telegram.org/bot#{token}/sendMessage")

      response = Net::HTTP.post_form(uri, {
        "chat_id" => chat_id,
        "text" => text,
        "parse_mode" => "MarkdownV2"
      })

      unless response.is_a?(Net::HTTPSuccess)
        raise "telegram API error: #{response.code} #{response.body}"
      end
    end

    def escape_md(text)
      text.to_s.gsub(/([_*\[\]()~`>#+\-=|{}.!\\])/, '\\\\\1')
    end
  end

  # Sends a macOS desktop notification via osascript.
  class DesktopNotifier
    def initialize(logger: NULL_LOGGER)
      @logger = logger
    end

    def notify(handler_output, metadata)
      title = metadata[:rule_name]
      message = handler_output["summary"]

      system(
        "osascript", "-e",
        %(display notification "#{escape_applescript(message)}" with title "#{escape_applescript(title)}")
      )
      @logger.info "desktop notification sent"
    end

    private

    def escape_applescript(text)
      text.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')
    end
  end
end
