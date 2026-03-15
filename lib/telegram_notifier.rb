# frozen_string_literal: true

require "net/http"
require "uri"
require "yaml"
module MailWorkflows
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
      yaml = YAML.safe_load_file(path, permitted_classes: [Symbol])
      yaml.dig("notifications", "telegram") || raise("missing notifications.telegram in accounts.yml")
    end

    HTTP_TIMEOUT = 15

    def send_message(text)
      token = config.fetch("token")
      chat_id = config.fetch("chat_id")
      uri = URI("https://api.telegram.org/bot#{token}/sendMessage")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT

      request = Net::HTTP::Post.new(uri)
      request.set_form_data(
        "chat_id" => chat_id,
        "text" => text,
        "parse_mode" => "MarkdownV2"
      )

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        raise "telegram API error: #{response.code} #{response.body}"
      end
    end

    def escape_md(text)
      text.to_s.gsub(/([_*\[\]()~`>#+\-=|{}.!\\])/, '\\\\\1')
    end
  end
end
