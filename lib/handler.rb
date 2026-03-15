# frozen_string_literal: true

require_relative "log"
require_relative "llm_handler"
require_relative "script_handler"

module MailWorkflows
  # Dispatches to the correct handler type based on rule config.
  module Handler
    module_function

    # Executes the handler for a rule and returns parsed output hash.
    # Raises on failure (non-zero exit).
    def execute(rule, input, home:, logger: NULL_LOGGER)
      handler_config = rule.handler
      type = handler_config.fetch("type", "llm")

      case type
      when "llm"
        LlmHandler.new(home, logger: logger).execute(handler_config, input)
      when "script"
        ScriptHandler.new(home, logger: logger).execute(handler_config, input)
      else
        raise "unknown handler type: #{type}"
      end
    end
  end
end
