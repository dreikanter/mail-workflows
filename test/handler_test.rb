# frozen_string_literal: true

require_relative "test_helper"

class HandlerDispatcherTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("handler-dispatch-test")
    @state_dir = File.join(@tmpdir, "state", "test-rule")
    FileUtils.mkdir_p(@state_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_dispatches_to_script_handler
    script = File.join(@tmpdir, "handler.sh")
    File.write(script, "#!/bin/bash\necho '{\"summary\": \"from script\", \"body\": \"\", \"data\": {}}'")
    File.chmod(0o755, script)

    rule = MailWorkflows::Rule.new(
      name: "test", match: {}, notify: [],
      handler: { "type" => "script", "command" => script }
    )

    output = MailWorkflows::Handler.execute(rule, sample_input, home: @tmpdir)
    assert_equal "from script", output["summary"]
  end

  def test_raises_on_unknown_handler_type
    rule = MailWorkflows::Rule.new(
      name: "test", match: {}, notify: [],
      handler: { "type" => "bogus" }
    )

    assert_raises(RuntimeError) do
      MailWorkflows::Handler.execute(rule, sample_input, home: @tmpdir)
    end
  end

  private

  def sample_input
    {
      "email" => {
        "message_id" => "<test@example.com>",
        "from" => "sender@example.com",
        "to" => "user@example.com",
        "subject" => "Test",
        "date" => "2026-03-01T08:00:00+00:00",
        "folder" => "INBOX",
        "body" => "body",
        "attachments" => [],
        "attachment_dir" => nil
      },
      "preprocessed" => {},
      "state_dir" => @state_dir,
      "config" => {}
    }
  end
end
