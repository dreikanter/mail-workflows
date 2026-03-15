# frozen_string_literal: true

require_relative "test_helper"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "log"
require "handler"
require "rule_set"

class ScriptHandlerTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("handler-test")
    @state_dir = File.join(@tmpdir, "state", "test-rule")
    FileUtils.mkdir_p(@state_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_script_handler_executes_and_parses_output
    script = write_script("handler.sh", <<~SH)
      #!/bin/bash
      cat <<'JSON'
      {"summary": "test summary", "body": "test body", "data": {}}
      JSON
    SH

    handler = MailWorkflows::ScriptHandler.new(@tmpdir)
    output = handler.execute({ "type" => "script", "command" => script }, sample_input)

    assert_equal "test summary", output["summary"]
    assert_equal "test body", output["body"]
  end

  def test_script_handler_receives_json_input
    script = write_script("handler.sh", <<~SH)
      #!/bin/bash
      # Read stdin and extract subject using ruby
      ruby -rjson -e 'data = JSON.parse(STDIN.read); puts JSON.generate({"summary" => data["email"]["subject"], "body" => "", "data" => {}})'
    SH

    handler = MailWorkflows::ScriptHandler.new(@tmpdir)
    output = handler.execute({ "type" => "script", "command" => script }, sample_input)

    assert_equal "Test Subject", output["summary"]
  end

  def test_script_handler_raises_on_failure
    script = write_script("fail.sh", <<~SH)
      #!/bin/bash
      echo "something went wrong" >&2
      exit 1
    SH

    handler = MailWorkflows::ScriptHandler.new(@tmpdir)

    assert_raises(RuntimeError) do
      handler.execute({ "type" => "script", "command" => script }, sample_input)
    end
  end

  def test_script_handler_raises_on_missing_summary
    script = write_script("handler.sh", <<~SH)
      #!/bin/bash
      echo '{"body": "no summary field"}'
    SH

    handler = MailWorkflows::ScriptHandler.new(@tmpdir)

    assert_raises(RuntimeError) do
      handler.execute({ "type" => "script", "command" => script }, sample_input)
    end
  end

  def test_script_handler_resolves_relative_path
    scripts_dir = File.join(@tmpdir, "handlers")
    FileUtils.mkdir_p(scripts_dir)
    script_path = File.join(scripts_dir, "test.sh")
    File.write(script_path, <<~SH)
      #!/bin/bash
      echo '{"summary": "ok", "body": "", "data": {}}'
    SH
    File.chmod(0o755, script_path)

    handler = MailWorkflows::ScriptHandler.new(@tmpdir)
    output = handler.execute({ "type" => "script", "command" => "handlers/test.sh" }, sample_input)

    assert_equal "ok", output["summary"]
  end

  private

  def write_script(name, content)
    path = File.join(@tmpdir, name)
    File.write(path, content)
    File.chmod(0o755, path)
    path
  end

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
end

class LlmHandlerTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("llm-handler-test")
    @state_dir = File.join(@tmpdir, "state", "test-rule")
    @prompts_dir = File.join(@tmpdir, "prompts")
    FileUtils.mkdir_p([@state_dir, @prompts_dir])
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_assembles_prompt_with_placeholders
    File.write(File.join(@prompts_dir, "test.md"), <<~MD)
      Analyze this email:

      {{EMAIL_CONTENT}}

      Attachments:
      {{PREPROCESSED}}
    MD

    handler = MailWorkflows::LlmHandler.new(@tmpdir)
    # Use send to test private method
    prompt = handler.send(:assemble_prompt, "test", sample_input)

    assert_includes prompt, "Test body content"
    assert_includes prompt, "Analyze this email"
  end

  def test_raises_on_missing_prompt_template
    handler = MailWorkflows::LlmHandler.new(@tmpdir)

    assert_raises(RuntimeError) do
      handler.send(:assemble_prompt, "nonexistent", sample_input)
    end
  end

  def test_includes_preprocessed_content
    File.write(File.join(@prompts_dir, "test.md"), "{{PREPROCESSED}}")

    input = sample_input.merge(
      "preprocessed" => { "doc.pdf" => "Extracted PDF content here" }
    )

    handler = MailWorkflows::LlmHandler.new(@tmpdir)
    prompt = handler.send(:assemble_prompt, "test", input)

    assert_includes prompt, "## doc.pdf"
    assert_includes prompt, "Extracted PDF content here"
  end

  def test_parses_claude_json_output
    handler = MailWorkflows::LlmHandler.new(@tmpdir)

    # Simulate claude --output-format json wrapping
    claude_output = JSON.generate({
      "type" => "result",
      "result" => '{"summary": "parsed ok", "body": "detail", "data": {}}'
    })

    result = handler.send(:parse_claude_output, claude_output)
    assert_equal "parsed ok", result["summary"]
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
end
