# frozen_string_literal: true

require_relative "test_helper"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "log"
require "notifier"

class DesktopNotifierTest < Minitest::Test
  def test_notify_calls_osascript
    notifier = MailWorkflows::DesktopNotifier.new
    handler_output = { "summary" => "Test notification" }
    metadata = { rule_name: "test-rule", from: "a@b.com", subject: "Hi", date: "2026-03-01" }

    # Just verify it doesn't raise — actual osascript call is OS-dependent
    notifier.notify(handler_output, metadata)
  end

  def test_escapes_special_characters
    notifier = MailWorkflows::DesktopNotifier.new
    escaped = notifier.send(:escape_applescript, 'He said "hello" \\ world')
    assert_includes escaped, '\\"'
  end
end

class TelegramNotifierTest < Minitest::Test
  def test_escapes_markdown_v2_characters
    notifier = MailWorkflows::TelegramNotifier.allocate
    escaped = notifier.send(:escape_md, "Hello *world* [link](url) ~strike~")
    assert_includes escaped, '\\*'
    assert_includes escaped, '\\['
    assert_includes escaped, '\\~'
  end
end

class EmailNotifierTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("notifier-test")
    write_accounts_yml
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_default_to_uses_from_address
    notifier = MailWorkflows::EmailNotifier.new(@tmpdir)
    to = notifier.send(:default_to)
    assert_equal "user@gmail.com", to
  end

  private

  def write_accounts_yml
    config = {
      "notifications" => {
        "email" => {
          "from" => "user@gmail.com",
          "smtp_host" => "smtp.gmail.com",
          "smtp_port" => 587,
          "smtp_user" => "user@gmail.com",
          "smtp_pass_cmd" => "echo test"
        }
      }
    }
    File.write(File.join(@tmpdir, "accounts.yml"), YAML.dump(config))
  end
end
