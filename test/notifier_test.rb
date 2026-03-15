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

  def test_escapes_markdown_v2_characters
    notifier = MailWorkflows::TelegramNotifier.allocate
    escaped = notifier.send(:escape_md, "Hello *world* [link](url) ~strike~")
    assert_includes escaped, '\\*'
    assert_includes escaped, '\\['
    assert_includes escaped, '\\~'
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
