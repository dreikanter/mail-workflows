# frozen_string_literal: true

require_relative "test_helper"

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

    captured_to = nil
    fake_mailer = Object.new
    fake_mailer.define_singleton_method(:deliver) do |to:, **_kw|
      captured_to = to
    end

    MailWorkflows::Mailer.stub(:new, fake_mailer) do
      notifier.notify(
        {},
        { "summary" => "test", "body" => "" },
        { rule_name: "r", from: "a@b.com", subject: "s", date: "2026-01-01" }
      )
    end

    assert_equal "user@gmail.com", captured_to
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
    File.write(File.join(@tmpdir, "config.yml"), YAML.dump(config))
  end
end
