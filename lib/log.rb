# frozen_string_literal: true

require "logger"

module MailWorkflows
  # Creates a logger that writes to both stderr and a log file.
  # Levels: DEBUG, INFO, WARN, ERROR
  def self.create_logger(level: Logger::INFO, home: nil)
    formatter = proc do |severity, time, _prog, msg|
      "[#{time.strftime("%Y-%m-%d %H:%M:%S")}] [#{severity[0]}] #{msg}\n"
    end

    targets = [$stderr]

    if home
      log_dir = File.join(home, "log")
      FileUtils.mkdir_p(log_dir)
      targets << File.open(File.join(log_dir, "sync.log"), "a")
    end

    logger = Logger.new(MultiIO.new(*targets))
    logger.level = level
    logger.formatter = formatter
    logger
  end

  # Null logger that discards all output. Useful as default in library classes
  # so callers don't have to pass a logger if they don't want logging.
  NULL_LOGGER = Logger.new(File.open(File::NULL, "w"))

  # Writes to multiple IO targets.
  class MultiIO
    def initialize(*targets)
      @targets = targets
    end

    def write(*args)
      @targets.each { |t| t.write(*args) }
    end

    def close
      @targets.each(&:close)
    end

    def flush
      @targets.each(&:flush)
    end
  end
end
