# frozen_string_literal: true

require_relative "test_helper"

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
