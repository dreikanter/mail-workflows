# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/maildir"

class MaildirTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("maildir-test")
    @maildir = MailWorkflows::Maildir.new(@tmpdir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_ensure_dirs_creates_subdirectories
    @maildir.ensure_dirs
    %w[new cur tmp].each do |sub|
      assert Dir.exist?(File.join(@tmpdir, sub)), "expected #{sub}/ to exist"
    end
  end

  def test_ensure_dirs_returns_self
    assert_equal @maildir, @maildir.ensure_dirs
  end

  def test_new_messages_returns_files_in_new
    @maildir.ensure_dirs
    create_message("new", "msg1")
    create_message("new", "msg2")

    assert_equal 2, @maildir.new_messages.size
    assert @maildir.new_messages.all? { |f| f.include?("/new/") }
  end

  def test_new_messages_sorted_by_mtime
    @maildir.ensure_dirs
    older = create_message("new", "older")
    newer = create_message("new", "newer")
    FileUtils.touch(older, mtime: Time.now - 10)

    assert_equal [older, newer], @maildir.new_messages
  end

  def test_new_messages_ignores_directories
    @maildir.ensure_dirs
    FileUtils.mkdir_p(File.join(@tmpdir, "new", "subdir"))
    create_message("new", "msg1")

    assert_equal 1, @maildir.new_messages.size
  end

  def test_cur_messages_returns_files_in_cur
    @maildir.ensure_dirs
    create_message("cur", "msg1")

    assert_equal 1, @maildir.cur_messages.size
    assert @maildir.cur_messages.first.include?("/cur/")
  end

  def test_read_returns_file_content
    @maildir.ensure_dirs
    path = create_message("new", "msg1", "From: test@example.com\n\nHello")

    assert_equal "From: test@example.com\n\nHello", @maildir.read(path)
  end

  def test_mark_processed_moves_to_cur
    @maildir.ensure_dirs
    path = create_message("new", "msg1")

    new_path = @maildir.mark_processed(path)

    assert_includes new_path, "/cur/"
    refute File.exist?(path)
    assert File.exist?(new_path)
    assert_equal 0, @maildir.new_messages.size
    assert_equal 1, @maildir.cur_messages.size
  end

  def test_mark_failed_moves_to_failed
    @maildir.ensure_dirs
    path = create_message("new", "msg1")

    new_path = @maildir.mark_failed(path)

    assert_includes new_path, "/failed/"
    refute File.exist?(path)
    assert File.exist?(new_path)
  end

  def test_mark_failed_creates_failed_dir
    @maildir.ensure_dirs
    path = create_message("new", "msg1")

    @maildir.mark_failed(path)

    assert Dir.exist?(File.join(@tmpdir, "failed"))
  end

  def test_to_s_returns_path
    assert_equal File.expand_path(@tmpdir), @maildir.to_s
  end

  private

  def create_message(subdir, name, content = "test content")
    path = File.join(@tmpdir, subdir, name)
    File.write(path, content)
    path
  end
end
