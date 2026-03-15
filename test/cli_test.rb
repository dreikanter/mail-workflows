# frozen_string_literal: true

require_relative "test_helper"

class CLITest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("cli-test")
    @mw = File.expand_path("../bin/mw", __dir__)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- version ---

  def test_version
    output = run_mw("version")
    assert_match(/\Amw \d+\.\d+\.\d+\n\z/, output)
  end

  # --- help ---

  def test_help
    output = run_mw("--help")
    assert_includes output, "Commands:"
    assert_includes output, "init"
    assert_includes output, "schedule"
  end

  def test_no_command_shows_usage
    output = run_mw("", expect_failure: true)
    assert_includes output, "Usage:"
  end

  def test_unknown_command
    output = run_mw("bogus", expect_failure: true)
    assert_includes output, "Unknown command: bogus"
  end

  # --- init ---

  def test_init_creates_directory_structure
    path = File.join(@tmpdir, "new-home")
    run_mw("init #{Shellwords.shellescape(path)}")

    %w[rules prompts mail normalized attachments state log].each do |dir|
      assert Dir.exist?(File.join(path, dir)), "Expected #{dir}/ to exist"
    end
    assert File.exist?(File.join(path, "accounts.yml"))
  end

  def test_init_uses_path_flag
    path = File.join(@tmpdir, "flagged")
    run_mw("--path #{Shellwords.shellescape(path)} init")

    assert Dir.exist?(File.join(path, "rules"))
    assert File.exist?(File.join(path, "accounts.yml"))
  end

  def test_init_refuses_existing_dir
    path = File.join(@tmpdir, "exists")
    FileUtils.mkdir_p(path)

    output = run_mw("init #{Shellwords.shellescape(path)}", expect_failure: true)
    assert_includes output, "already exists"
  end

  def test_init_force_recreates
    path = File.join(@tmpdir, "force")
    FileUtils.mkdir_p(File.join(path, "stale"))

    run_mw("init --force #{Shellwords.shellescape(path)}")

    assert Dir.exist?(File.join(path, "rules"))
    refute Dir.exist?(File.join(path, "stale"))
  end

  def test_init_preserves_existing_accounts_yml
    path = File.join(@tmpdir, "preserve")
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "accounts.yml"), "custom: true\n")

    run_mw("init --force #{Shellwords.shellescape(path)}")

    assert_equal "custom: true\n", File.read(File.join(path, "accounts.yml"))
  end

  # --- purge ---

  def test_purge_requires_confirm
    output = run_mw("--path #{Shellwords.shellescape(@tmpdir)} purge", expect_failure: true)
    assert_includes output, "--confirm"
  end

  def test_purge_removes_data_dirs
    %w[mail/acct/INBOX/new normalized/acct/new attachments/slug].each do |dir|
      FileUtils.mkdir_p(File.join(@tmpdir, dir))
    end
    File.write(File.join(@tmpdir, "mail/acct/INBOX/new/msg.eml"), "data")

    run_mw("--path #{Shellwords.shellescape(@tmpdir)} purge --confirm")

    refute Dir.exist?(File.join(@tmpdir, "mail"))
    refute Dir.exist?(File.join(@tmpdir, "normalized"))
    refute Dir.exist?(File.join(@tmpdir, "attachments"))
  end

  def test_purge_preserves_config
    FileUtils.mkdir_p(File.join(@tmpdir, "mail"))
    FileUtils.mkdir_p(File.join(@tmpdir, "rules"))
    File.write(File.join(@tmpdir, "accounts.yml"), "accounts: {}")
    File.write(File.join(@tmpdir, "rules/test.yml"), "match: {}")

    run_mw("--path #{Shellwords.shellescape(@tmpdir)} purge --confirm")

    assert File.exist?(File.join(@tmpdir, "accounts.yml"))
    assert File.exist?(File.join(@tmpdir, "rules/test.yml"))
  end

  def test_purge_succeeds_when_dirs_missing
    run_mw("--path #{Shellwords.shellescape(@tmpdir)} purge --confirm")
    # No error — exit 0
  end

  # --- schedule period parsing ---

  def test_schedule_rejects_invalid_period
    output = run_mw("--path #{Shellwords.shellescape(@tmpdir)} schedule abc", expect_failure: true)
    assert_includes output, "Invalid period"
  end

  def test_schedule_rejects_zero_minutes
    output = run_mw("--path #{Shellwords.shellescape(@tmpdir)} schedule 0m", expect_failure: true)
    assert_includes output, "Minutes must be between"
  end

  private

  def run_mw(args, expect_failure: false)
    output = `ruby #{Shellwords.shellescape(@mw)} #{args} 2>&1`
    if expect_failure
      refute $?.success?, "Expected failure but got success. Output: #{output}"
    else
      assert $?.success?, "Command failed (exit #{$?.exitstatus}): #{output}"
    end
    output
  end
end
