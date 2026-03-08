# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/maildir_store"

class MaildirStoreTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("maildir-store-test")
    write_accounts_yml(
      "accounts" => {
        "personal" => {
          "host" => "imap.example.com",
          "user" => "user@example.com",
          "pass_cmd" => "echo secret",
          "folders" => ["INBOX", "Sent"]
        }
      }
    )
    @store = MailWorkflows::MaildirStore.new(@tmpdir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_home_returns_configured_path
    assert_equal @tmpdir, @store.home
  end

  def test_maildirs_returns_one_per_folder
    maildirs = @store.maildirs

    assert_equal 2, maildirs.size
    assert_includes maildirs.map(&:to_s), File.join(@tmpdir, "mail", "personal", "INBOX")
    assert_includes maildirs.map(&:to_s), File.join(@tmpdir, "mail", "personal", "Sent")
  end

  def test_maildirs_defaults_to_inbox
    write_accounts_yml(
      "accounts" => {
        "work" => {
          "host" => "imap.work.com",
          "user" => "user@work.com",
          "pass_cmd" => "echo secret"
        }
      }
    )
    store = MailWorkflows::MaildirStore.new(@tmpdir)

    assert_equal 1, store.maildirs.size
    assert_includes store.maildirs.first.to_s, "INBOX"
  end

  def test_maildirs_with_multiple_accounts
    write_accounts_yml(
      "accounts" => {
        "personal" => { "host" => "a.com", "user" => "a@a.com", "pass_cmd" => "echo x", "folders" => ["INBOX"] },
        "work" => { "host" => "b.com", "user" => "b@b.com", "pass_cmd" => "echo y", "folders" => ["INBOX", "Archive"] }
      }
    )
    store = MailWorkflows::MaildirStore.new(@tmpdir)

    assert_equal 3, store.maildirs.size
  end

  def test_ensure_all_dirs_creates_maildir_structures
    @store.ensure_all_dirs

    %w[INBOX Sent].each do |folder|
      %w[new cur tmp].each do |sub|
        dir = File.join(@tmpdir, "mail", "personal", folder, sub)
        assert Dir.exist?(dir), "expected #{dir} to exist"
      end
    end
  end

  def test_each_new_message_yields_messages_with_maildir
    @store.ensure_all_dirs
    inbox = @store.maildirs.find { |m| m.to_s.include?("INBOX") }
    File.write(File.join(inbox.path, "new", "msg1"), "content")

    results = []
    @store.each_new_message { |msg, md, acct, folder| results << [File.basename(msg), md, acct, folder] }

    assert_equal 1, results.size
    assert_equal "msg1", results.first[0]
    assert_equal inbox.to_s, results.first[1].to_s
    assert_equal "personal", results.first[2]
    assert_equal "INBOX", results.first[3]
  end

  def test_each_new_message_returns_enumerator_without_block
    @store.ensure_all_dirs

    assert_kind_of Enumerator, @store.each_new_message
  end

  def test_each_new_message_spans_all_maildirs
    @store.ensure_all_dirs
    @store.maildirs.each_with_index do |md, i|
      File.write(File.join(md.path, "new", "msg#{i}"), "content")
    end

    count = @store.each_new_message.count

    assert_equal 2, count
  end

  private

  def write_accounts_yml(data)
    File.write(File.join(@tmpdir, "accounts.yml"), YAML.dump(data))
  end
end
