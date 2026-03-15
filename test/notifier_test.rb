# frozen_string_literal: true

require_relative "test_helper"

class TelegramNotifierTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("telegram-test")
    write_telegram_config
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_escapes_markdown_v2_characters_in_notification
    notifier = MailWorkflows::TelegramNotifier.new(@tmpdir)

    sent_body = nil
    fake_response = Net::HTTPSuccess.allocate
    fake_http = Minitest::Mock.new
    fake_http.expect(:use_ssl=, nil, [true])
    fake_http.expect(:open_timeout=, nil, [15])
    fake_http.expect(:read_timeout=, nil, [15])
    fake_http.expect(:request, fake_response) { |req| sent_body = req.body; true }

    Net::HTTP.stub(:new, fake_http) do
      notifier.notify(
        {},
        { "summary" => "Hello *world* [link] ~strike~" },
        { rule_name: "test", from: "a@b.com", subject: "s" }
      )
    end

    # The sent body is URL-encoded form data; decode to check escaping
    text_param = URI.decode_www_form(sent_body).assoc("text")&.last
    assert_includes text_param, '\\*'
    assert_includes text_param, '\\['
    assert_includes text_param, '\\~'
  end

  def test_notify_sends_http_request
    notifier = MailWorkflows::TelegramNotifier.new(@tmpdir)

    sent_body = nil
    fake_response = Net::HTTPSuccess.allocate
    fake_http = Minitest::Mock.new
    fake_http.expect(:use_ssl=, nil, [true])
    fake_http.expect(:open_timeout=, nil, [15])
    fake_http.expect(:read_timeout=, nil, [15])
    fake_http.expect(:request, fake_response) { |req| sent_body = req.body; true }

    Net::HTTP.stub(:new, fake_http) do
      notifier.notify(
        {},
        { "summary" => "test summary" },
        { rule_name: "test-rule", from: "a@b.com", subject: "Hello" }
      )
    end

    assert_includes sent_body, "test-token-chat"
    fake_http.verify
  end

  def test_notify_raises_on_api_error
    notifier = MailWorkflows::TelegramNotifier.new(@tmpdir)

    fake_response = Net::HTTPBadRequest.allocate
    fake_response.define_singleton_method(:code) { "400" }
    fake_response.define_singleton_method(:body) { "Bad Request" }

    fake_http = Minitest::Mock.new
    fake_http.expect(:use_ssl=, nil, [true])
    fake_http.expect(:open_timeout=, nil, [15])
    fake_http.expect(:read_timeout=, nil, [15])
    fake_http.expect(:request, fake_response) { true }

    Net::HTTP.stub(:new, fake_http) do
      err = assert_raises(RuntimeError) do
        notifier.notify(
          {},
          { "summary" => "test" },
          { rule_name: "r", from: "a@b.com", subject: "s" }
        )
      end
      assert_match(/telegram API error/, err.message)
    end
  end

  private

  def write_telegram_config
    config = {
      "notifications" => {
        "telegram" => {
          "token" => "test-token",
          "chat_id" => "test-token-chat"
        }
      }
    }
    File.write(File.join(@tmpdir, "accounts.yml"), YAML.dump(config))
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

    captured_to = nil
    fake_mailer = Object.new
    fake_mailer.define_singleton_method(:send) do |to:, **_kw|
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
    File.write(File.join(@tmpdir, "accounts.yml"), YAML.dump(config))
  end
end
