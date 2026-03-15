# frozen_string_literal: true

require_relative "test_helper"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "log"
require "processor"

class ProcessorTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("processor-test")
    %w[rules prompts normalized/personal/new normalized/personal/processed state].each do |dir|
      FileUtils.mkdir_p(File.join(@tmpdir, dir))
    end
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- No rules ---

  def test_no_rules_moves_all_to_processed
    write_email("personal", "20260301-080000_test-email.md",
      from: "sender@example.com", subject: "Hello", body: "Hi there")

    processor = MailWorkflows::Processor.new(@tmpdir)
    counts = processor.run

    assert_equal 1, counts[:processed]
    assert_equal 0, counts[:matched]
    assert_empty Dir.glob(File.join(@tmpdir, "normalized/personal/new/*.md"))
    assert_equal 1, Dir.glob(File.join(@tmpdir, "normalized/personal/processed/*.md")).size
  end

  # --- Rule matching ---

  def test_matching_rule_runs_handler
    write_rule("01-test.yml",
      name: "test-rule",
      match: { "from" => "bank.com" },
      handler: { "type" => "script", "command" => write_handler_script })

    write_email("personal", "20260301-080000_statement.md",
      from: "noreply@bank.com", subject: "Monthly Statement", body: "Your balance is $100")

    processor = MailWorkflows::Processor.new(@tmpdir)
    counts = processor.run

    assert_equal 1, counts[:matched]
    assert_empty Dir.glob(File.join(@tmpdir, "normalized/personal/new/*.md"))
    assert_equal 1, Dir.glob(File.join(@tmpdir, "normalized/personal/processed/*.md")).size
  end

  def test_handler_output_saved_to_state_dir
    write_rule("01-test.yml",
      name: "test-rule",
      match: { "from" => "bank.com" },
      handler: { "type" => "script", "command" => write_handler_script })

    write_email("personal", "20260301-080000_statement.md",
      from: "noreply@bank.com", subject: "Monthly Statement", body: "Balance")

    processor = MailWorkflows::Processor.new(@tmpdir)
    processor.run

    state_files = Dir.glob(File.join(@tmpdir, "state/test-rule/*.json"))
    assert_equal 1, state_files.size

    output = JSON.parse(File.read(state_files.first))
    assert_equal "test summary", output["summary"]
  end

  # --- Non-matching email ---

  def test_non_matching_email_moves_to_processed
    write_rule("01-test.yml",
      name: "test-rule",
      match: { "from" => "bank.com" },
      handler: { "type" => "script", "command" => write_handler_script })

    write_email("personal", "20260301-080000_random.md",
      from: "friend@example.com", subject: "Hey", body: "What's up?")

    processor = MailWorkflows::Processor.new(@tmpdir)
    counts = processor.run

    assert_equal 1, counts[:processed]
    assert_equal 0, counts[:matched]
  end

  # --- Multiple accounts ---

  def test_processes_multiple_accounts
    FileUtils.mkdir_p(File.join(@tmpdir, "normalized/work/new"))
    FileUtils.mkdir_p(File.join(@tmpdir, "normalized/work/processed"))

    write_email("personal", "20260301-080000_email1.md",
      from: "a@b.com", subject: "One", body: "Body 1")
    write_email("work", "20260301-080000_email2.md",
      from: "c@d.com", subject: "Two", body: "Body 2")

    processor = MailWorkflows::Processor.new(@tmpdir)
    counts = processor.run

    assert_equal 2, counts[:processed]
    assert_empty Dir.glob(File.join(@tmpdir, "normalized/*/new/*.md"))
  end

  # --- Retry tracking ---

  def test_handler_failure_increments_retries
    write_rule("01-test.yml",
      name: "test-rule",
      match: { "from" => "bank.com" },
      handler: { "type" => "script", "command" => write_failing_script })

    md_path = write_email("personal", "20260301-080000_fail.md",
      from: "noreply@bank.com", subject: "Fail", body: "Body")

    processor = MailWorkflows::Processor.new(@tmpdir)
    counts = processor.run

    # Email should stay in new/
    assert File.exist?(md_path)
    retries_file = "#{md_path}.retries"
    assert File.exist?(retries_file)
    assert_equal "1", File.read(retries_file).strip
    # Handler failure counts as error, not double-counted
    assert_equal 1, counts[:errors]
    assert_equal 0, counts[:matched]
  end

  def test_max_retries_moves_to_failed
    write_rule("01-test.yml",
      name: "test-rule",
      match: { "from" => "bank.com" },
      handler: { "type" => "script", "command" => write_failing_script })

    md_path = write_email("personal", "20260301-080000_fail.md",
      from: "noreply@bank.com", subject: "Fail", body: "Body")

    # Pre-set retries to max
    File.write("#{md_path}.retries", "3")

    processor = MailWorkflows::Processor.new(@tmpdir)
    counts = processor.run

    assert_equal 1, counts[:failed]
    refute File.exist?(md_path)
    assert_equal 1, Dir.glob(File.join(@tmpdir, "normalized/personal/failed/*.md")).size
    # Retries file should be cleaned up
    refute File.exist?("#{md_path}.retries")
  end

  # --- Preprocessed content ---

  def test_loads_preprocessed_pdf_content
    write_rule("01-test.yml",
      name: "test-rule",
      match: { "from" => "bank.com" },
      handler: { "type" => "script", "command" => write_echo_input_script })

    stem = "20260301-080000_statement"
    att_dir = File.join(@tmpdir, "attachments", stem)
    FileUtils.mkdir_p(att_dir)
    File.write(File.join(att_dir, "report.pdf.md"), "Extracted PDF content")

    write_email("personal", "#{stem}.md",
      from: "noreply@bank.com", subject: "Statement", body: "See attached")

    processor = MailWorkflows::Processor.new(@tmpdir)
    processor.run

    # Read the saved state output to verify preprocessed was passed
    state_files = Dir.glob(File.join(@tmpdir, "state/test-rule/*.json"))
    output = JSON.parse(File.read(state_files.first))
    # The echo script returns the input's preprocessed field in data
    assert_equal "Extracted PDF content", output["data"]["preprocessed"]["report.pdf"]
  end

  # --- Handler input structure ---

  def test_handler_input_contains_expected_fields
    write_rule("01-test.yml",
      name: "test-rule",
      match: { "from" => "bank.com" },
      handler: { "type" => "script", "command" => write_echo_input_script, "model" => "haiku" })

    write_email("personal", "20260301-080000_test.md",
      from: "noreply@bank.com",
      to: "user@example.com",
      subject: "Test Email",
      body: "Body text",
      extra_frontmatter: { "folder" => "INBOX", "message_id" => "<test@example.com>" })

    processor = MailWorkflows::Processor.new(@tmpdir)
    processor.run

    state_files = Dir.glob(File.join(@tmpdir, "state/test-rule/*.json"))
    output = JSON.parse(File.read(state_files.first))
    input = output["data"]["input"]

    assert_equal "<test@example.com>", input["email"]["message_id"]
    assert_equal "noreply@bank.com", input["email"]["from"]
    assert_equal "Body text", input["email"]["body"]
    assert_equal({ "model" => "haiku" }, input["config"])
    assert input["state_dir"].end_with?("state/test-rule")
  end

  # --- Cleanup retries on success ---

  def test_cleans_up_retries_file_on_success
    write_rule("01-test.yml",
      name: "test-rule",
      match: { "from" => "bank.com" },
      handler: { "type" => "script", "command" => write_handler_script })

    md_path = write_email("personal", "20260301-080000_retry.md",
      from: "noreply@bank.com", subject: "Retry", body: "Body")

    # Pre-existing retries file from previous failures
    File.write("#{md_path}.retries", "2")

    processor = MailWorkflows::Processor.new(@tmpdir)
    processor.run

    refute File.exist?("#{md_path}.retries")
  end

  # --- Notification failure resilience ---

  def test_notification_failure_does_not_block_processing
    write_rule("01-test.yml",
      name: "test-rule",
      match: { "from" => "bank.com" },
      handler: { "type" => "script", "command" => write_handler_script },
      notify: [{ "type" => "telegram" }])

    # No accounts.yml with telegram config → TelegramNotifier will raise
    write_email("personal", "20260301-080000_notify-fail.md",
      from: "noreply@bank.com", subject: "Statement", body: "Body")

    processor = MailWorkflows::Processor.new(@tmpdir)
    counts = processor.run

    # Email should still be processed successfully despite notification failure
    assert_equal 1, counts[:matched]
    assert_empty Dir.glob(File.join(@tmpdir, "normalized/personal/new/*.md"))
    assert_equal 1, Dir.glob(File.join(@tmpdir, "normalized/personal/processed/*.md")).size
  end

  # --- Frontmatter parsing ---

  def test_invalid_frontmatter_counts_as_error
    # Write a file without proper frontmatter delimiters
    dir = File.join(@tmpdir, "normalized", "personal", "new")
    File.write(File.join(dir, "20260301-080000_bad.md"), "no frontmatter here")

    processor = MailWorkflows::Processor.new(@tmpdir)
    counts = processor.run

    assert_equal 1, counts[:errors]
  end

  def test_body_with_markdown_horizontal_rule_does_not_corrupt_parsing
    write_rule("01-test.yml",
      name: "test-rule",
      match: { "from" => "bank.com" },
      handler: { "type" => "script", "command" => write_echo_input_script })

    write_email("personal", "20260301-080000_hr.md",
      from: "noreply@bank.com", subject: "Report",
      body: "Before separator\n\n---\n\nAfter separator")

    processor = MailWorkflows::Processor.new(@tmpdir)
    counts = processor.run

    assert_equal 1, counts[:matched]
    state_files = Dir.glob(File.join(@tmpdir, "state/test-rule/*.json"))
    output = JSON.parse(File.read(state_files.first))
    body = output["data"]["input"]["email"]["body"]
    assert_includes body, "Before separator"
    assert_includes body, "After separator"
  end

  private

  def write_email(account, filename, from:, subject:, body:, to: "user@example.com", extra_frontmatter: {})
    dir = File.join(@tmpdir, "normalized", account, "new")
    FileUtils.mkdir_p(dir)

    frontmatter = {
      "message_id" => "<#{filename}@test>",
      "from" => from,
      "to" => to,
      "subject" => subject,
      "date" => "2026-03-01T08:00:00+00:00",
      "folder" => "INBOX"
    }.merge(extra_frontmatter)

    content = "---\n#{YAML.dump(frontmatter).sub(/\A---\n/, "")}---\n\n#{body}\n"
    path = File.join(dir, filename)
    File.write(path, content)
    path
  end

  def write_rule(filename, name:, match:, handler:, notify: [])
    data = { "name" => name, "match" => match, "handler" => handler, "notify" => notify }
    File.write(File.join(@tmpdir, "rules", filename), YAML.dump(data))
  end

  def write_handler_script
    path = File.join(@tmpdir, "handler.sh")
    File.write(path, <<~SH)
      #!/bin/bash
      echo '{"summary": "test summary", "body": "test body", "data": {}}'
    SH
    File.chmod(0o755, path)
    path
  end

  def write_failing_script
    path = File.join(@tmpdir, "fail.sh")
    File.write(path, <<~SH)
      #!/bin/bash
      echo "error" >&2
      exit 1
    SH
    File.chmod(0o755, path)
    path
  end

  def write_echo_input_script
    path = File.join(@tmpdir, "echo_input.sh")
    File.write(path, <<~SH)
      #!/bin/bash
      ruby -rjson -e '
        input = JSON.parse(STDIN.read)
        output = {
          "summary" => "echo",
          "body" => "",
          "data" => { "input" => input, "preprocessed" => input["preprocessed"] }
        }
        puts JSON.generate(output)
      '
    SH
    File.chmod(0o755, path)
    path
  end
end
