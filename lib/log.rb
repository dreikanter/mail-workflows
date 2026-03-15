# frozen_string_literal: true

require "logger"

module MailWorkflows
  # Creates a stderr logger with a compact single-line format.
  # Levels: DEBUG, INFO, WARN, ERROR
  def self.create_logger(level: Logger::INFO)
    logger = Logger.new($stderr)
    logger.level = level
    logger.formatter = proc do |severity, _time, _prog, msg|
      "#{severity[0]} #{msg}\n"
    end
    logger
  end

  # Null logger that discards all output. Useful as default in library classes
  # so callers don't have to pass a logger if they don't want logging.
  NULL_LOGGER = Logger.new(File.open(File::NULL, "w"))
end
