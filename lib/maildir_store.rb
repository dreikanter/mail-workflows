# frozen_string_literal: true

require "yaml"
module MailWorkflows
  # Manages all Maildir folders across configured accounts.
  # Reads account configuration from config.yml and provides
  # access to individual Maildir instances.
  class MaildirStore
    attr_reader :home

    def initialize(home = nil)
      @home = home || ENV.fetch("MAIL_WORKFLOWS_HOME", File.expand_path("~/.mail-workflows"))
    end

    # Returns array of {account:, folder:, maildir:} hashes
    # for all configured account/folder pairs.
    def maildir_entries
      accounts.flat_map do |name, account|
        folders = account.fetch("folders", ["INBOX"])
        folders.map do |folder|
          {
            account: name,
            folder: folder,
            maildir: Maildir.new(File.join(mail_path, name, folder))
          }
        end
      end
    end

    # Returns array of Maildir instances for all configured account/folder pairs.
    def maildirs
      maildir_entries.map { |e| e[:maildir] }
    end

    # Create all Maildir directory structures.
    def ensure_all_dirs
      maildirs.each(&:ensure_dirs)
    end

    # Iterate over new (unprocessed) messages across all maildirs.
    # Yields [filepath, maildir, account, folder] tuples.
    def each_new_message
      return enum_for(:each_new_message) unless block_given?

      maildir_entries.each do |entry|
        entry[:maildir].new_messages.each do |msg|
          yield msg, entry[:maildir], entry[:account], entry[:folder]
        end
      end
    end

    private

    def config
      unless File.exist?(config_path)
        raise "config.yml not found at #{config_path}. Run 'mw init' first."
      end

      @config ||= YAML.safe_load_file(config_path, permitted_classes: [Symbol])
    end

    def accounts
      config.fetch("accounts", {})
    end

    def config_path
      File.join(@home, "config.yml")
    end

    def mail_path
      File.join(@home, "mail")
    end
  end
end
