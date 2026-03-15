# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/mbsyncrc_generator"

class MbsyncrcGeneratorTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("mbsyncrc-test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_generates_mbsyncrc_from_accounts
    write_accounts(
      "accounts" => {
        "personal" => {
          "host" => "imap.gmail.com",
          "port" => 993,
          "user" => "user@gmail.com",
          "pass_cmd" => "echo secret",
          "tls" => true,
          "folders" => ["INBOX"]
        }
      }
    )

    run_generator

    rc = read_mbsyncrc
    assert_includes rc, "IMAPAccount personal"
    assert_includes rc, "Host imap.gmail.com"
    assert_includes rc, "Port 993"
    assert_includes rc, "User user@gmail.com"
    assert_includes rc, 'PassCmd "echo secret"'
    assert_includes rc, "TLSType IMAPS"
    assert_includes rc, "AuthMechs LOGIN"
    assert_includes rc, "IMAPStore personal-remote"
    assert_includes rc, "MaildirStore personal-local"
    assert_includes rc, "Channel personal"
    assert_includes rc, "Patterns INBOX"
    assert_includes rc, "Sync Pull"
    assert_includes rc, "Create Near"
    assert_includes rc, "Expunge None"
  end

  def test_tls_false_sets_none
    write_accounts(
      "accounts" => {
        "local" => {
          "host" => "localhost",
          "user" => "user",
          "pass_cmd" => "echo x",
          "tls" => false
        }
      }
    )

    run_generator

    assert_includes read_mbsyncrc, "TLSType None"
  end

  def test_default_tls_is_imaps
    write_accounts(
      "accounts" => {
        "nossl" => {
          "host" => "imap.example.com",
          "user" => "user",
          "pass_cmd" => "echo x"
        }
      }
    )

    run_generator

    assert_includes read_mbsyncrc, "TLSType IMAPS"
  end

  def test_multiple_folders_in_patterns
    write_accounts(
      "accounts" => {
        "work" => {
          "host" => "imap.work.com",
          "user" => "user@work.com",
          "pass_cmd" => "echo x",
          "folders" => ["INBOX", "Sent", "Archive"]
        }
      }
    )

    run_generator

    assert_includes read_mbsyncrc, "Patterns INBOX Sent Archive"
  end

  def test_creates_maildir_directories
    write_accounts(
      "accounts" => {
        "test" => {
          "host" => "imap.test.com",
          "user" => "user@test.com",
          "pass_cmd" => "echo x",
          "folders" => ["INBOX", "Drafts"]
        }
      }
    )

    run_generator

    %w[INBOX Drafts].each do |folder|
      %w[new cur tmp].each do |sub|
        dir = File.join(@tmpdir, "mail", "test", folder, sub)
        assert Dir.exist?(dir), "expected #{dir} to exist"
      end
    end
  end

  def test_mbsyncrc_file_permissions
    write_accounts("accounts" => { "a" => { "host" => "h", "user" => "u", "pass_cmd" => "echo x" } })

    run_generator

    mode = File.stat(File.join(@tmpdir, ".mbsyncrc")).mode & 0o777
    assert_equal 0o600, mode
  end

  def test_multiple_accounts_separated_by_blank_line
    write_accounts(
      "accounts" => {
        "first" => { "host" => "a.com", "user" => "a", "pass_cmd" => "echo x" },
        "second" => { "host" => "b.com", "user" => "b", "pass_cmd" => "echo y" }
      }
    )

    run_generator

    rc = read_mbsyncrc
    assert_includes rc, "IMAPAccount first"
    assert_includes rc, "IMAPAccount second"
    assert_includes rc, "Channel first"
    assert_includes rc, "Channel second"
  end

  private

  def write_accounts(data)
    File.write(File.join(@tmpdir, "accounts.yml"), YAML.dump(data))
  end

  def run_generator
    MailWorkflows::MbsyncrcGenerator.new(@tmpdir).run
  end

  def read_mbsyncrc
    File.read(File.join(@tmpdir, ".mbsyncrc"))
  end
end
