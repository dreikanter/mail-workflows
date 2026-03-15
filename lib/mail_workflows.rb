# frozen_string_literal: true

require_relative "log"
require_relative "version"

module MailWorkflows
  autoload :CLI, File.expand_path("cli", __dir__)
  autoload :EmailNotifier, File.expand_path("email_notifier", __dir__)
  autoload :Handler, File.expand_path("handler", __dir__)
  autoload :LlmHandler, File.expand_path("llm_handler", __dir__)
  autoload :Maildir, File.expand_path("maildir", __dir__)
  autoload :MaildirStore, File.expand_path("maildir_store", __dir__)
  autoload :Mailer, File.expand_path("mailer", __dir__)
  autoload :MbsyncrcGenerator, File.expand_path("mbsyncrc_generator", __dir__)
  autoload :Normalizer, File.expand_path("normalizer", __dir__)
  autoload :Notifier, File.expand_path("notifier", __dir__)
  autoload :Processor, File.expand_path("processor", __dir__)
  autoload :Rule, File.expand_path("rule_set", __dir__)
  autoload :RuleSet, File.expand_path("rule_set", __dir__)
  autoload :ScriptHandler, File.expand_path("script_handler", __dir__)
  autoload :Slug, File.expand_path("slug", __dir__)
  autoload :TelegramNotifier, File.expand_path("telegram_notifier", __dir__)
end
