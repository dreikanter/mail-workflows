# frozen_string_literal: true

require "fileutils"

module MailWorkflows
  # Represents a single Maildir folder (e.g., ~/.mail-workflows/mail/personal/INBOX).
  # Provides operations for listing, reading, and moving messages between
  # Maildir subdirectories (new/, cur/, tmp/).
  class Maildir
    SUBDIRS = %w[new cur tmp].freeze

    attr_reader :path

    def initialize(path)
      @path = File.expand_path(path)
    end

    # Create new/, cur/, tmp/ subdirectories if they don't exist.
    def ensure_dirs
      SUBDIRS.each { |d| FileUtils.mkdir_p(File.join(@path, d)) }
      self
    end

    # List unprocessed message file paths (sorted by mtime, oldest first).
    def new_messages
      list("new")
    end

    # List processed message file paths.
    def cur_messages
      list("cur")
    end

    # Read raw message content from a file path.
    def read(filepath)
      File.read(filepath)
    end

    # Move message from new/ to cur/ (marks as processed).
    # Returns the new file path.
    def mark_processed(filepath)
      move_to(filepath, "cur")
    end

    # Move message to failed/ subdirectory.
    # Returns the new file path.
    def mark_failed(filepath)
      move_to(filepath, "failed")
    end

    def to_s
      @path
    end

    private

    def list(subdir)
      Dir.glob(File.join(@path, subdir, "*"))
         .select { |f| File.file?(f) }
         .sort_by { |f| File.mtime(f) }
    end

    def move_to(filepath, subdir)
      dest_dir = File.join(@path, subdir)
      FileUtils.mkdir_p(dest_dir)
      dest = File.join(dest_dir, File.basename(filepath))
      File.rename(filepath, dest)
      dest
    end
  end
end
