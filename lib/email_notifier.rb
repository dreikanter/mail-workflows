# frozen_string_literal: true

require "yaml"
module MailWorkflows
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

      mailer.deliver(to: to, subject: subject, body: body)
      @logger.info "email notification sent to #{to}"
    end

    private

    def default_to
      config_path = File.join(@home, "config.yml")
      yaml = YAML.safe_load_file(config_path, permitted_classes: [Symbol])
      yaml.dig("notifications", "email", "from") || raise("no default email recipient configured")
    end
  end
end
