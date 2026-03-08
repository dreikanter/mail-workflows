# frozen_string_literal: true

require_relative "test_helper"
require "mail"
require "securerandom"
require_relative "../lib/normalizer"

class NormalizerTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("normalizer-test")
    @normalizer = MailWorkflows::Normalizer.new(@tmpdir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_normalizes_plain_text_email
    eml = build_eml(
      from: "alice@example.com",
      to: "bob@example.com",
      subject: "Hello Bob",
      body: "This is a plain text message."
    )
    path = write_eml(eml)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert md_path
    content = File.read(md_path)
    assert_match(/^message_id:/, content)
    assert_match(/^from:.*alice@example\.com/, content)
    assert_match(/^to:.*bob@example\.com/, content)
    assert_match(/^subject: Hello Bob/, content)
    assert_match(/^folder: INBOX/, content)
    assert_includes content, "This is a plain text message."
  end

  def test_normalizes_html_only_email
    html_body = "<html><body><h1>Hello</h1><p>This is <strong>bold</strong> text.</p></body></html>"
    eml = build_html_eml(
      from: "alice@example.com",
      to: "bob@example.com",
      subject: "HTML Email",
      html: html_body
    )
    path = write_eml(eml)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(md_path)
    # Should contain markdown-converted content
    assert_includes content, "Hello"
    assert_includes content, "bold"
    # Should not contain raw HTML tags
    refute_includes content, "<h1>"
    refute_includes content, "<strong>"
  end

  def test_prefers_text_plain_over_html
    eml = build_multipart_eml(
      from: "alice@example.com",
      to: "bob@example.com",
      subject: "Multipart",
      text: "Plain text version.",
      html: "<p>HTML version.</p>"
    )
    path = write_eml(eml)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(md_path)
    assert_includes content, "Plain text version."
  end

  def test_extracts_attachments
    eml = build_eml(
      from: "alice@example.com",
      to: "bob@example.com",
      subject: "With Attachment",
      body: "See attached.",
      attachments: [{ name: "report.pdf", content: "fake pdf content" }]
    )
    path = write_eml(eml)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")
    stem = File.basename(md_path, ".md")

    att_dir = File.join(@tmpdir, "attachments", stem)
    assert Dir.exist?(att_dir), "attachments directory should exist"
    assert File.exist?(File.join(att_dir, "report.pdf"))
    assert_equal "fake pdf content", File.read(File.join(att_dir, "report.pdf"))

    # Frontmatter should list attachment
    content = File.read(md_path)
    assert_match(/attachments:/, content)
    assert_match(/report\.pdf/, content)
  end

  def test_handles_inline_images
    mail = Mail.new do
      from    "alice@example.com"
      to      "bob@example.com"
      subject "Inline Image"
    end
    mail.text_part = Mail::Part.new(body: "See image below.")
    inline = Mail::Part.new
    inline.content_type = "image/png; filename=logo.png"
    inline.content_disposition = "inline; filename=logo.png"
    inline.body = "fake png data"
    inline.content_transfer_encoding = "base64"
    inline.body = ["\x89PNG fake"].pack("m")
    mail.add_part(inline)
    path = write_eml(mail.to_s)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")
    stem = File.basename(md_path, ".md")

    att_dir = File.join(@tmpdir, "attachments", stem)
    assert Dir.exist?(att_dir), "attachments dir should exist for inline images"
    assert File.exist?(File.join(att_dir, "logo.png"))
  end

  def test_filename_slug_from_subject
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "Invoice from Acme Corp",
      body: "test"
    )
    path = write_eml(eml)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert_match(/invoice-from-acme-corp\.md\z/, md_path)
  end

  def test_handles_non_ascii_subject
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "Café Résumé",
      body: "test"
    )
    path = write_eml(eml)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert_match(/cafe-resume\.md\z/, md_path)
  end

  def test_handles_empty_subject
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "",
      body: "test"
    )
    path = write_eml(eml)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert_match(/no-subject\.md\z/, md_path)
  end

  def test_decodes_quoted_printable_body
    mail = Mail.new
    mail.from = "a@example.com"
    mail.to = "b@example.com"
    mail.subject = "QP Test"
    mail.content_type = "text/plain; charset=UTF-8"
    mail.content_transfer_encoding = "quoted-printable"
    mail.body = "Hello =C3=BCber world"
    path = write_eml(mail.to_s)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(md_path)
    assert_includes content, "über"
  end

  def test_decodes_base64_body
    mail = Mail.new
    mail.from = "a@example.com"
    mail.to = "b@example.com"
    mail.subject = "Base64 Test"
    mail.content_type = "text/plain; charset=UTF-8"
    mail.content_transfer_encoding = "base64"
    mail.body = ["Hello base64 world"].pack("m")
    path = write_eml(mail.to_s)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(md_path)
    assert_includes content, "Hello base64 world"
  end

  def test_decodes_percent_encoded_attachment_filenames
    mail = Mail.new do
      from    "a@example.com"
      to      "b@example.com"
      subject "Encoded Attachment"
    end
    mail.text_part = Mail::Part.new(body: "See attached.")
    att = Mail::Part.new
    att.content_type = 'application/pdf; name="FD-POS%2b260228%2b2%2b1%2b159237%2bmusaev.dtd.pdf"'
    att.content_disposition = 'attachment; filename="FD-POS%2b260228%2b2%2b1%2b159237%2bmusaev.dtd.pdf"'
    att.body = "fake pdf"
    mail.add_part(att)
    path = write_eml(mail.to_s)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")
    stem = File.basename(md_path, ".md")
    att_dir = File.join(@tmpdir, "attachments", stem)

    # Parse attachment names from frontmatter
    content = File.read(md_path)
    frontmatter = YAML.safe_load(content.split("---\n")[1])
    listed_names = frontmatter["attachments"]

    assert_equal ["FD-POS+260228+2+1+159237+musaev.dtd.pdf"], listed_names
    # Every name in frontmatter must exist on disk
    listed_names.each do |name|
      assert File.exist?(File.join(att_dir, name)),
             "frontmatter attachment '#{name}' should exist on disk"
    end
  end

  def test_handles_duplicate_attachment_names
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "Dup Attachments",
      body: "Two files.",
      attachments: [
        { name: "file.pdf", content: "first" },
        { name: "file.pdf", content: "second" }
      ]
    )
    path = write_eml(eml)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")
    stem = File.basename(md_path, ".md")
    att_dir = File.join(@tmpdir, "attachments", stem)

    assert File.exist?(File.join(att_dir, "file.pdf"))
    assert File.exist?(File.join(att_dir, "file-2.pdf"))
  end

  def test_skips_already_normalized_message
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "Idempotent",
      body: "test"
    )
    path1 = write_eml(eml)
    path2 = write_eml(eml, "copy.eml")

    md_path1 = @normalizer.normalize(path1, account: "personal", folder: "INBOX")
    md_path2 = @normalizer.normalize(path2, account: "personal", folder: "INBOX")

    assert md_path1, "first normalization should succeed"
    assert_nil md_path2, "second normalization should be skipped"
  end

  def test_collision_suffix_on_filename_clash
    eml1 = build_eml(from: "a@example.com", to: "b@example.com", subject: "Same Subject", body: "first",
                     message_id: "msg1@example.com")
    eml2 = build_eml(from: "a@example.com", to: "b@example.com", subject: "Same Subject", body: "second",
                     message_id: "msg2@example.com")
    # Set same date so timestamps match
    path1 = write_eml(eml1, "msg1.eml")
    path2 = write_eml(eml2, "msg2.eml")

    md1 = @normalizer.normalize(path1, account: "personal", folder: "INBOX")
    md2 = @normalizer.normalize(path2, account: "personal", folder: "INBOX")

    assert md1
    assert md2
    refute_equal md1, md2
    # One should have a suffix
    stems = [File.basename(md1, ".md"), File.basename(md2, ".md")]
    assert stems.any? { |s| s.match?(/_[0-9a-f]{8}\z/) }, "expected collision suffix on one file"
  end

  def test_creates_normalized_directory_structure
    eml = build_eml(from: "a@example.com", to: "b@example.com", subject: "Test", body: "test")
    path = write_eml(eml)

    @normalizer.normalize(path, account: "work", folder: "INBOX")

    assert Dir.exist?(File.join(@tmpdir, "normalized", "work", "new"))
  end

  def test_no_attachments_dir_when_no_attachments
    eml = build_eml(from: "a@example.com", to: "b@example.com", subject: "No Atts", body: "plain")
    path = write_eml(eml)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")
    stem = File.basename(md_path, ".md")

    refute Dir.exist?(File.join(@tmpdir, "attachments", stem))
  end

  def test_strips_email_signature
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "With Sig",
      body: "Main content.\n\n-- \nJohn Doe\nCEO, Example Corp"
    )
    path = write_eml(eml)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(md_path)
    assert_includes content, "Main content."
    refute_includes content, "CEO, Example Corp"
  end

  def test_large_headers_with_many_recipients
    recipients = (1..20).map { |i| "user#{i}@example.com" }.join(", ")
    eml = build_eml(
      from: "sender@example.com",
      to: recipients,
      subject: "Large Headers",
      body: "test"
    )
    path = write_eml(eml)

    md_path = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert md_path
    content = File.read(md_path)
    assert_match(/^to:/, content)
  end

  private

  def build_eml(from:, to:, subject:, body:, attachments: [], message_id: nil)
    mail = Mail.new do
      from    from
      to      to
      subject subject
      body    body
    end
    mail.message_id = message_id if message_id
    attachments.each do |a|
      mail.add_file(filename: a[:name], content: a[:content])
    end
    mail.to_s
  end

  def build_html_eml(from:, to:, subject:, html:)
    mail = Mail.new do
      from         from
      to           to
      subject      subject
      content_type "text/html; charset=UTF-8"
      body         html
    end
    mail.to_s
  end

  def build_multipart_eml(from:, to:, subject:, text:, html:)
    mail = Mail.new do
      from    from
      to      to
      subject subject
    end
    mail.text_part = Mail::Part.new(body: text)
    mail.html_part = Mail::Part.new(content_type: "text/html; charset=UTF-8", body: html)
    mail.to_s
  end

  def write_eml(content, filename = nil)
    filename ||= "#{SecureRandom.hex(8)}.eml"
    dir = File.join(@tmpdir, "eml")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, filename)
    File.write(path, content)
    path
  end
end
