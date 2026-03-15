# frozen_string_literal: true

require "fileutils"
require "logger"

module MailWorkflows
  # Creates a logger that writes to both stderr and a rotating log file.
  # Levels: DEBUG, INFO, WARN, ERROR
  def self.create_logger(level: Logger::INFO, home: nil)
    formatter = proc do |severity, time, _prog, msg|
      "[#{time.strftime("%Y-%m-%d %H:%M:%S")}] [#{severity[0]}] #{msg}\n"
    end

    stderr_logger = Logger.new($stderr)
    stderr_logger.level = level
    stderr_logger.formatter = formatter

    return stderr_logger unless home

    log_dir = File.join(home, "log")
    FileUtils.mkdir_p(log_dir)
    file_logger = Logger.new(File.join(log_dir, "sync.log"), 5, 10_485_760)
    file_logger.level = level
    file_logger.formatter = formatter

    BroadcastLogger.new(stderr_logger, file_logger)
  end

  # Null logger that discards all output. Useful as default in library classes
  # so callers don't have to pass a logger if they don't want logging.
  NULL_LOGGER = Logger.new(File::NULL)

  # Broadcasts log messages to multiple loggers.
  class BroadcastLogger
    def initialize(*loggers)
      @loggers = loggers
    end

    %i[debug info warn error fatal unknown].each do |m|
      define_method(m) do |*args, &block|
        @loggers.each { |l| l.send(m, *args, &block) }
      end
    end

    def level
      @loggers.first&.level
    end

    def level=(val)
      @loggers.each { |l| l.level = val }
    end

    def close
      @loggers.each(&:close)
    end
  end
end
