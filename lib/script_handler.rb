# frozen_string_literal: true

require "json"
require "open3"
require_relative "log"

module MailWorkflows
  # Runs an arbitrary executable with JSON input on stdin.
  class ScriptHandler
    def initialize(home, logger: NULL_LOGGER)
      @home = home
      @logger = logger
    end

    def execute(config, input)
      command = config.fetch("command")
      # Resolve relative paths against the tool repo
      command = File.expand_path(command, @home) unless command.start_with?("/")

      @logger.info "script handler: #{command}"

      stdout, stderr, status = Open3.capture3(command, stdin_data: JSON.generate(input))

      unless status.success?
        @logger.error "script exited #{status.exitstatus}: #{stderr}"
        raise "script failed (exit #{status.exitstatus}): #{stderr.lines.first&.chomp}"
      end

      output = JSON.parse(stdout)
      validate_output(output)
      output
    end

    private

    def validate_output(output)
      raise "handler output missing 'summary'" unless output.key?("summary")
    end
  end
end
