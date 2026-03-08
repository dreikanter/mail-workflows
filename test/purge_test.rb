# frozen_string_literal: true

require_relative "test_helper"

class PurgeTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("purge-test")
    @script = File.expand_path("../bin/purge", __dir__)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_removes_mail_normalized_and_attachments
    create_tree("mail/personal/INBOX/new/msg.eml")
    create_tree("normalized/personal/new/20260308-120000_hello.md")
    create_tree("attachments/20260308-120000_hello/invoice.pdf")

    run_purge

    refute Dir.exist?(File.join(@tmpdir, "mail"))
    refute Dir.exist?(File.join(@tmpdir, "normalized"))
    refute Dir.exist?(File.join(@tmpdir, "attachments"))
  end

  def test_preserves_config_files
    create_tree("mail/personal/INBOX/new/msg.eml")
    write_file("accounts.yml", "accounts: {}")
    write_file("rules/bank.yml", "match: {}")
    write_file("prompts/bank.md", "prompt")

    run_purge

    assert File.exist?(File.join(@tmpdir, "accounts.yml"))
    assert File.exist?(File.join(@tmpdir, "rules/bank.yml"))
    assert File.exist?(File.join(@tmpdir, "prompts/bank.md"))
  end

  def test_succeeds_when_dirs_missing
    # Empty home dir — nothing to remove
    run_purge
  end

  def test_partial_dirs
    create_tree("normalized/work/new/msg.md")
    # mail/ and attachments/ don't exist

    run_purge

    refute Dir.exist?(File.join(@tmpdir, "normalized"))
    refute Dir.exist?(File.join(@tmpdir, "mail"))
    refute Dir.exist?(File.join(@tmpdir, "attachments"))
  end

  private

  def create_tree(rel_path)
    path = File.join(@tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "test data")
  end

  def write_file(rel_path, content)
    path = File.join(@tmpdir, rel_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def run_purge
    output = `bash #{Shellwords.shellescape(@script)} --home #{Shellwords.shellescape(@tmpdir)} 2>&1`
    assert $?.success?, "purge failed: #{output}"
  end
end
