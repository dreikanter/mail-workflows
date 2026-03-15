# frozen_string_literal: true

require_relative "log"
require_relative "email_notifier"
require_relative "telegram_notifier"
module MailWorkflows
  # Dispatches notifications to the correct notifier type.
  module Notifier
    module_function

    # Sends a notification for a handler result.
    # notify_config is a single entry from the rule's notify array.
    # metadata contains email info (from, subject, date, rule_name).
    def notify(notify_config, handler_output, metadata, home:, logger: NULL_LOGGER)
      type = notify_config.fetch("type")

      case type
      when "email"
        EmailNotifier.new(home, logger: logger).notify(notify_config, handler_output, metadata)
      when "telegram"
        TelegramNotifier.new(home, logger: logger).notify(notify_config, handler_output, metadata)
      else
        logger.warn "unknown notifier type: #{type}"
      end
    end
  end
end
