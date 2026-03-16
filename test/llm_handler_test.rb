# frozen_string_literal: true

require_relative "test_helper"

class LlmHandlerTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("llm-handler-test")
    @state_dir = File.join(@tmpdir, "state", "test-rule")
    FileUtils.mkdir_p(@state_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_assembles_prompt_with_placeholders
    write_prompt("test", <<~MD)
      Analyze this email:

      {{EMAIL_CONTENT}}

      Attachments:
      {{PREPROCESSED}}
    MD

    captured_stdin = nil
    handler = MailWorkflows::LlmHandler.new(@tmpdir)
    status = stub_success_status

    Open3.stub(:capture3, lambda { |*_args, stdin_data: nil, **_kw|
      captured_stdin = stdin_data
      [claude_json_response("prompt check"), "", status]
    }) do
      handler.execute({ "prompt" => "test" }, sample_input)
    end

    assert_includes captured_stdin, "Test body content"
    assert_includes captured_stdin, "Analyze this email"
  end

  def test_raises_on_missing_prompt_template
    handler = MailWorkflows::LlmHandler.new(@tmpdir)

    assert_raises(RuntimeError) do
      handler.execute({ "prompt" => "nonexistent" }, sample_input)
    end
  end

  def test_includes_preprocessed_content
    write_prompt("test", "{{PREPROCESSED}}")

    input = sample_input.merge(
      "preprocessed" => { "doc.pdf" => "Extracted PDF content here" }
    )

    captured_stdin = nil
    handler = MailWorkflows::LlmHandler.new(@tmpdir)
    status = stub_success_status

    Open3.stub(:capture3, lambda { |*_args, stdin_data: nil, **_kw|
      captured_stdin = stdin_data
      [claude_json_response("preprocessed check"), "", status]
    }) do
      handler.execute({ "prompt" => "test" }, input)
    end

    assert_includes captured_stdin, "## doc.pdf"
    assert_includes captured_stdin, "Extracted PDF content here"
  end

  def test_parses_claude_json_output
    write_prompt("test", "{{EMAIL_CONTENT}}")

    handler = MailWorkflows::LlmHandler.new(@tmpdir)
    status = stub_success_status

    claude_output = JSON.generate({
                                    "type" => "result",
                                    "result" => '{"summary": "parsed ok", "body": "detail", "data": {}}'
                                  })

    Open3.stub(:capture3, [claude_output, "", status]) do
      result = handler.execute({ "prompt" => "test" }, sample_input)
      assert_equal "parsed ok", result["summary"]
    end
  end

  def test_execute_success
    write_prompt("test", "Analyze: {{EMAIL_CONTENT}}")

    handler = MailWorkflows::LlmHandler.new(@tmpdir)
    status = stub_success_status

    Open3.stub(:capture3, [claude_json_response("test result"), "", status]) do
      result = handler.execute({ "prompt" => "test" }, sample_input)
      assert_equal "test result", result["summary"]
    end
  end

  def test_execute_raises_on_claude_failure
    write_prompt("test", "{{EMAIL_CONTENT}}")

    handler = MailWorkflows::LlmHandler.new(@tmpdir)
    status = Object.new
    status.define_singleton_method(:success?) { false }
    status.define_singleton_method(:exitstatus) { 1 }

    Open3.stub(:capture3, ["", "error msg", status]) do
      err = assert_raises(RuntimeError) { handler.execute({ "prompt" => "test" }, sample_input) }
      assert_match(/claude failed/, err.message)
    end
  end

  def test_execute_raises_on_timeout
    write_prompt("test", "{{EMAIL_CONTENT}}")

    handler = MailWorkflows::LlmHandler.new(@tmpdir)

    Open3.stub(:capture3, ->(*_args, **_kw) { raise Timeout::Error }) do
      assert_raises(Timeout::Error) { handler.execute({ "prompt" => "test" }, sample_input) }
    end
  end

  private

  def sample_input
    {
      "email" => {
        "message_id" => "<test@example.com>",
        "from" => "sender@example.com",
        "to" => "user@example.com",
        "subject" => "Test Subject",
        "date" => "2026-03-01T08:00:00+00:00",
        "folder" => "INBOX",
        "body" => "Test body content",
        "attachments" => [],
        "attachment_dir" => nil
      },
      "preprocessed" => {},
      "state_dir" => @state_dir,
      "config" => {}
    }
  end

  def stub_success_status
    status = Object.new
    status.define_singleton_method(:success?) { true }
    status
  end

  def write_prompt(name, content)
    config_path = File.join(@tmpdir, "config.yml")
    config = File.exist?(config_path) ? (YAML.safe_load_file(config_path) || {}) : {}
    config["prompts"] ||= {}
    config["prompts"][name] = content
    File.write(config_path, YAML.dump(config))
  end

  def claude_json_response(summary)
    JSON.generate({
                    "type" => "result",
                    "result" => JSON.generate({ "summary" => summary, "body" => "", "data" => {} })
                  })
  end
end
