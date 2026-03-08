# frozen_string_literal: true

require "fileutils"
require "yaml"

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

  # Manages all Maildir folders across configured accounts.
  # Reads account configuration from accounts.yml and provides
  # access to individual Maildir instances.
  class MaildirStore
    attr_reader :home

    def initialize(home = nil)
      @home = home || ENV.fetch("MAIL_WORKFLOWS_HOME", File.expand_path("~/.mail-workflows"))
    end

    def config
      @config ||= YAML.load_file(accounts_path, permitted_classes: [Symbol])
    end

    def accounts
      config.fetch("accounts", {})
    end

    def accounts_path
      File.join(@home, "accounts.yml")
    end

    def mail_path
      File.join(@home, "mail")
    end

    # Returns array of Maildir instances for all configured account/folder pairs.
    def maildirs
      accounts.flat_map do |name, account|
        folders = account.fetch("folders", ["INBOX"])
        folders.map do |folder|
          Maildir.new(File.join(mail_path, name, folder))
        end
      end
    end

    # Create all Maildir directory structures.
    def ensure_all_dirs
      maildirs.each(&:ensure_dirs)
    end

    # Iterate over new (unprocessed) messages across all maildirs.
    # Yields [filepath, maildir] pairs.
    def each_new_message
      return enum_for(:each_new_message) unless block_given?

      maildirs.each do |maildir|
        maildir.new_messages.each { |msg| yield msg, maildir }
      end
    end
  end
end
