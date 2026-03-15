# frozen_string_literal: true

require "mail"
require "yaml"
require_relative "log"

module MailWorkflows
  # Sends email via SMTP using credentials from accounts.yml.
  # Reads SMTP settings from the notifications.email section.
  #
  # Usage:
  #   mailer = Mailer.new(home)
  #   mailer.send(to: "a@b.com", subject: "Hi", body: "Hello")
  #   mailer.send(to: "a@b.com", subject: "Hi", html: "<h1>Hello</h1>")
  class Mailer
    def initialize(home, logger: NULL_LOGGER)
      @home = home
      @logger = logger
      @config = load_config
    end

    def send(to:, subject:, body: nil, html: nil, cc: nil)
      raise ArgumentError, "body or html required" unless body || html

      msg = build_message(to: to, subject: subject, body: body, html: html, cc: cc)
      msg.deliver!

      @logger.info "sent email to=#{to} subject=#{subject.inspect}"
      msg
    end

    private

    attr_reader :config

    def build_message(to:, subject:, body:, html:, cc:)
      smtp = smtp_settings
      from = config.fetch("from")

      Mail.new do
        from    from
        to      to
        cc      cc if cc
        subject subject

        if html
          text_part { body body } if body
          html_part do
            content_type "text/html; charset=UTF-8"
            body html
          end
        else
          body body
        end

        delivery_method :smtp, smtp
      end
    end

    def smtp_settings
      password = resolve_password

      {
        address: config.fetch("smtp_host"),
        port: config.fetch("smtp_port"),
        user_name: config.fetch("smtp_user"),
        password: password,
        authentication: "plain",
        enable_starttls_auto: true
      }
    end

    def resolve_password
      cmd = config.fetch("smtp_pass_cmd")
      password = `#{cmd}`.chomp
      raise "smtp_pass_cmd failed (exit #{$?.exitstatus}): #{cmd}" unless $?.success?

      password
    end

    def load_config
      path = File.join(@home, "accounts.yml")
      yaml = YAML.load_file(path)
      email_config = yaml.dig("notifications", "email")
      raise "missing notifications.email in #{path}" unless email_config

      email_config
    end
  end
end
