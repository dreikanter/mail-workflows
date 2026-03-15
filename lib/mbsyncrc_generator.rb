# frozen_string_literal: true

require "yaml"
require "fileutils"
module MailWorkflows
  # Generates .mbsyncrc from accounts.yml and ensures Maildir directories exist.
  class MbsyncrcGenerator
    def initialize(home, logger: NULL_LOGGER)
      @home = home
      @logger = logger
    end

    def run
      config_path = File.join(@home, "accounts.yml")
      unless File.exist?(config_path)
        raise "accounts.yml not found at #{config_path}. Run 'mw init' first."
      end

      @logger.info "loading accounts from #{config_path}"
      config = YAML.safe_load_file(config_path, permitted_classes: [Symbol])
      accounts = config.fetch("accounts", {})
      @logger.info "found #{accounts.size} account(s): #{accounts.keys.join(", ")}"

      rc_path = generate_rc(accounts)
      create_maildirs(accounts)
      rc_path
    end

    private

    def generate_rc(accounts)
      rc_path = File.join(@home, ".mbsyncrc")

      File.open(rc_path, "w", 0o600) do |f|
        accounts.each_with_index do |(name, acct), i|
          f.puts "" if i > 0

          tls_type = acct.fetch("tls", true) ? "IMAPS" : "None"
          folders = acct.fetch("folders", ["INBOX"])
          store_path = File.join(@home, "mail", name) + "/"

          @logger.info "account #{name}: #{acct["host"]}:#{acct.fetch("port", 993)} " \
                        "tls=#{tls_type} folders=#{folders.join(",")}"

          f.puts "IMAPAccount #{name}"
          f.puts "Host #{acct["host"]}"
          f.puts "Port #{acct.fetch("port", 993)}"
          f.puts "User #{acct["user"]}"
          f.puts "PassCmd \"#{acct["pass_cmd"].gsub('"', '\\"')}\""
          f.puts "TLSType #{tls_type}"
          f.puts "AuthMechs LOGIN"
          f.puts ""
          f.puts "IMAPStore #{name}-remote"
          f.puts "Account #{name}"
          f.puts ""
          f.puts "MaildirStore #{name}-local"
          f.puts "Subfolders Verbatim"
          f.puts "Path #{store_path}"
          f.puts "Inbox #{File.join(store_path, "INBOX")}"
          f.puts ""
          f.puts "Channel #{name}"
          f.puts "Far :#{name}-remote:"
          f.puts "Near :#{name}-local:"
          f.puts "Patterns #{folders.join(" ")}"
          f.puts "Create Near"
          f.puts "Expunge None"
          f.puts "Sync Pull"
          f.puts "SyncState *"
        end
      end

      @logger.info "wrote #{rc_path}"
      rc_path
    end

    def create_maildirs(accounts)
      accounts.each do |name, acct|
        acct.fetch("folders", ["INBOX"]).each do |folder|
          dir = File.join(@home, "mail", name, folder)
          %w[new cur tmp].each { |sub| FileUtils.mkdir_p(File.join(dir, sub)) }
          @logger.info "maildir ready: #{dir}"
        end
      end
    end
  end
end
