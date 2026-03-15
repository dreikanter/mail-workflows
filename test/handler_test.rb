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

    captured_stdin = nil
    handler = MailWorkflows::LlmHandler.new(@tmpdir)
    status = stub_success_status

    Open3.stub(:capture3, ->(*_args, stdin_data: nil, **_kw) {
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
    File.write(File.join(@prompts_dir, "test.md"), "{{PREPROCESSED}}")

    input = sample_input.merge(
      "preprocessed" => { "doc.pdf" => "Extracted PDF content here" }
    )

    captured_stdin = nil
    handler = MailWorkflows::LlmHandler.new(@tmpdir)
    status = stub_success_status

    Open3.stub(:capture3, ->(*_args, stdin_data: nil, **_kw) {
      captured_stdin = stdin_data
      [claude_json_response("preprocessed check"), "", status]
    }) do
      handler.execute({ "prompt" => "test" }, input)
    end

    assert_includes captured_stdin, "## doc.pdf"
    assert_includes captured_stdin, "Extracted PDF content here"
  end

  def test_parses_claude_json_output
    File.write(File.join(@prompts_dir, "test.md"), "{{EMAIL_CONTENT}}")

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
    File.write(File.join(@prompts_dir, "test.md"), "Analyze: {{EMAIL_CONTENT}}")

    handler = MailWorkflows::LlmHandler.new(@tmpdir)
    status = stub_success_status

    Open3.stub(:capture3, [claude_json_response("test result"), "", status]) do
      result = handler.execute({ "prompt" => "test" }, sample_input)
      assert_equal "test result", result["summary"]
    end
  end

  def test_execute_raises_on_claude_failure
    File.write(File.join(@prompts_dir, "test.md"), "{{EMAIL_CONTENT}}")

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
    File.write(File.join(@prompts_dir, "test.md"), "{{EMAIL_CONTENT}}")

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

  def claude_json_response(summary)
    JSON.generate({
      "type" => "result",
      "result" => JSON.generate({ "summary" => summary, "body" => "", "data" => {} })
    })
  end
end
