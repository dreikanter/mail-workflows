# frozen_string_literal: true

require "optparse"
require "fileutils"
require "shellwords"
require "tmpdir"
require "yaml"
require_relative "version"

module MailWorkflows
  class CLI
    CRON_MARKER = "# mail-workflows"
    PURGE_DIRS = %w[mail normalized attachments].freeze

    def initialize(argv)
      @argv = argv.dup
      @home = ENV.fetch("MAIL_WORKFLOWS_HOME", File.expand_path("~/.mail-workflows"))
    end

    def run
      parse_global_options
      command = @argv.shift

      case command
      when "init"       then cmd_init
      when "run"        then cmd_run
      when "schedule"   then cmd_schedule
      when "unschedule" then cmd_unschedule
      when "status"     then cmd_status
      when "purge"      then cmd_purge
      when "version"    then cmd_version
      when nil          then abort usage
      else abort "Unknown command: #{command}\n\n#{usage}"
      end
    end

    private

    def parse_global_options
      OptionParser.new do |o|
        o.banner = "Usage: mw [--path DIR] <command> [options]"
        o.on("--path DIR", "Data directory") { |v| @home = File.expand_path(v) }
        o.on("--version", "Show version") { cmd_version; exit }
        o.on("-h", "--help", "Show help") { puts help_text; exit }
      end.order!(@argv)
    end

    # --- Commands ---

    def cmd_init
      force = false
      OptionParser.new do |o|
        o.on("--force", "Delete and recreate") { force = true }
      end.order!(@argv)

      path = @argv.shift || @home

      if Dir.exist?(path) && !force
        abort "Directory already exists: #{path}\nUse --force to recreate."
      end

      if force && Dir.exist?(path)
        # Preserve user config, remove everything else
        preserve = %w[accounts.yml rules prompts]
        preserved = {}
        preserve.each do |name|
          src = File.join(path, name)
          next unless File.exist?(src) || Dir.exist?(src)
          tmp = Dir.mktmpdir
          FileUtils.cp_r(src, File.join(tmp, name))
          preserved[name] = tmp
        end

        FileUtils.rm_rf(path)

        FileUtils.mkdir_p(path)
        preserved.each do |name, tmp|
          FileUtils.cp_r(File.join(tmp, name), File.join(path, name))
          FileUtils.rm_rf(tmp)
        end
      end

      %w[rules prompts mail normalized attachments artifacts log].each do |dir|
        FileUtils.mkdir_p(File.join(path, dir))
      end

      accounts_path = File.join(path, "accounts.yml")
      File.write(accounts_path, accounts_template) unless File.exist?(accounts_path)

      puts "Initialized #{path}"
    end

    def cmd_run
      require_relative "log"
      require_relative "mbsyncrc_generator"
      require_relative "maildir_store"
      require_relative "normalizer"

      lock_path = File.join(@home, ".lock")
      FileUtils.mkdir_p(File.dirname(lock_path))
      lock_file = File.open(lock_path, File::CREAT | File::WRONLY)

      unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
        $stderr.puts "Already running, skipping."
        exit 0
      end

      log = MailWorkflows.create_logger(home: @home)
      sync_mail(log)
    end

    def cmd_schedule
      period = @argv.shift
      abort "Usage: mw schedule <period> (e.g. 5m, 15m, 1h)" unless period

      cron_expr = parse_period(period)
      mw_bin = File.expand_path("../../bin/mw", __FILE__)
      log_path = File.join(@home, "log", "cron.log")

      entry = "#{cron_expr} #{Shellwords.shellescape(mw_bin)} --path #{Shellwords.shellescape(@home)} run" \
              " >> #{Shellwords.shellescape(log_path)} 2>&1 #{CRON_MARKER}"

      lines = current_crontab_lines.reject { |l| l.include?(CRON_MARKER) }
      lines << entry
      install_crontab(lines)

      puts "Scheduled: #{period} (#{cron_expr})"
    end

    def cmd_unschedule
      lines = current_crontab_lines
      if lines.any? { |l| l.include?(CRON_MARKER) }
        lines.reject! { |l| l.include?(CRON_MARKER) }
        install_crontab(lines)
        puts "Unscheduled."
      else
        puts "Not scheduled."
      end
    end

    def cmd_status
      cron_line = current_crontab_lines.find { |l| l.include?(CRON_MARKER) }
      if cron_line
        puts "Schedule: active"
        puts "  #{cron_line.sub(/ *#{Regexp.escape(CRON_MARKER)}$/, "")}"
      else
        puts "Schedule: inactive"
      end

      puts ""
      puts "Data directory: #{@home}"

      accounts_path = File.join(@home, "accounts.yml")
      if File.exist?(accounts_path)
        config = YAML.load_file(accounts_path, permitted_classes: [Symbol]) || {}
        accounts = config.fetch("accounts", {})
        if accounts.any?
          puts "Accounts:"
          accounts.each do |name, acct|
            folders = acct.fetch("folders", ["INBOX"])
            puts "  #{name}: #{acct["host"]} (#{folders.join(", ")})"
          end
        else
          puts "Accounts: none configured"
        end
      else
        puts "Accounts: not configured (no accounts.yml)"
      end
    end

    def cmd_purge
      confirm = false
      OptionParser.new do |o|
        o.on("--confirm", "Confirm deletion") { confirm = true }
      end.parse!(@argv)

      unless confirm
        abort "This will delete all mail, normalized, and attachment data.\nUse --confirm to proceed."
      end

      PURGE_DIRS.each do |dir|
        path = File.join(@home, dir)
        if Dir.exist?(path)
          $stderr.puts "removing #{path}"
          FileUtils.rm_rf(path)
        end
      end

      $stderr.puts "purge complete"
    end

    def cmd_version
      puts "mw #{MailWorkflows::VERSION}"
    end

    # --- Sync (extracted from former bin/sync) ---

    def sync_mail(log)
      MailWorkflows::MbsyncrcGenerator.new(@home, logger: log).run

      log.info "syncing mail"
      system("mbsync", "-c", File.join(@home, ".mbsyncrc"), "-a", exception: true)

      store = MailWorkflows::MaildirStore.new(@home)
      normalizer = MailWorkflows::Normalizer.new(@home, logger: log)

      count = 0
      errors = 0

      store.each_new_message do |filepath, maildir, account, folder|
        result = normalizer.normalize(filepath, account: account, folder: folder)
        if result
          maildir.mark_processed(filepath)
          count += 1
        end
      rescue StandardError => e
        errors += 1
        log.error "failed to normalize #{File.basename(filepath)}: #{e.message}"
        log.info e.backtrace.first(5).join("\n")
      end

      log.info "done: #{count} normalized, #{errors} errors"
    end

    # --- Helpers ---

    def parse_period(period)
      match = period.match(/\A(\d+)(m|h)\z/)
      abort "Invalid period: #{period}. Use e.g. 5m, 15m, 1h, 2h." unless match

      n = match[1].to_i
      unit = match[2]

      case unit
      when "m"
        abort "Minutes must be between 1 and 59." unless n.between?(1, 59)
        "*/#{n} * * * *"
      when "h"
        abort "Hours must be between 1 and 23." unless n.between?(1, 23)
        n == 1 ? "0 * * * *" : "0 */#{n} * * *"
      end
    end

    def current_crontab_lines
      `crontab -l 2>/dev/null`.lines.map(&:chomp)
    end

    def install_crontab(lines)
      IO.popen("crontab -", "w") { |io| io.puts lines.join("\n") }
    end

    def accounts_template
      <<~YAML
        # Mail Workflows - Account Configuration
        #
        # See README.md for setup instructions.
        #
        # accounts:
        #   personal:
        #     host: imap.gmail.com
        #     port: 993
        #     user: user@gmail.com
        #     pass_cmd: "security find-generic-password -s mail-workflows-personal -w"
        #     tls: true
        #     folders:
        #       - INBOX
      YAML
    end

    def usage
      "Usage: mw [--path DIR] <command> [options]\n\nRun 'mw --help' for details."
    end

    def help_text
      <<~HELP
        Usage: mw [--path DIR] <command> [options]

        Commands:
          init [PATH]        Initialize data directory structure
          run                Sync and process mail
          schedule <period>  Enable cron schedule (e.g. 5m, 15m, 1h)
          unschedule         Disable cron schedule
          status             Show scheduling status and config summary
          purge              Delete mail, normalized, and attachment data
          version            Show version

        Global options:
          --path DIR         Data directory (default: $MAIL_WORKFLOWS_HOME or ~/.mail-workflows)
          -h, --help         Show this help
          --version          Show version
      HELP
    end
  end
end
