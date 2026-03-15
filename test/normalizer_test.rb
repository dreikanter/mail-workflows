# frozen_string_literal: true

require_relative "test_helper"
require "mail"
require "securerandom"

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

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert result
    content = File.read(result.path)
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

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
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

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
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

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")
    stem = File.basename(result.path, ".md")

    att_dir = File.join(@tmpdir, "attachments", stem)
    assert Dir.exist?(att_dir), "attachments directory should exist"
    assert_path_exists File.join(att_dir, "report.pdf")
    assert_equal "fake pdf content", File.read(File.join(att_dir, "report.pdf"))

    # Frontmatter should list attachment
    content = File.read(result.path)
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

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")
    stem = File.basename(result.path, ".md")

    att_dir = File.join(@tmpdir, "attachments", stem)
    assert Dir.exist?(att_dir), "attachments dir should exist for inline images"
    assert_path_exists File.join(att_dir, "logo.png")
  end

  def test_filename_slug_from_subject
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "Invoice from Acme Corp",
      body: "test"
    )
    path = write_eml(eml)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert_match(/invoice-from-acme-corp\.md\z/, result.path)
  end

  def test_handles_non_ascii_subject
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "Café Résumé",
      body: "test"
    )
    path = write_eml(eml)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert_match(/cafe-resume\.md\z/, result.path)
  end

  def test_handles_empty_subject
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "",
      body: "test"
    )
    path = write_eml(eml)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert_match(/no-subject\.md\z/, result.path)
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

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
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

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
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
    att.content_type = 'application/pdf; name="FD-POS%2b260228%2b2%2b1%2b159237%2baccount.pdf"'
    att.content_disposition = 'attachment; filename="FD-POS%2b260228%2b2%2b1%2b159237%2baccount.pdf"'
    att.body = "fake pdf"
    mail.add_part(att)
    path = write_eml(mail.to_s)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")
    stem = File.basename(result.path, ".md")
    att_dir = File.join(@tmpdir, "attachments", stem)

    # Parse attachment names from frontmatter
    content = File.read(result.path)
    frontmatter = YAML.safe_load(content.split("---\n")[1])
    listed_names = frontmatter["attachments"]

    assert_equal ["FD-POS-260228-2-1-159237-account.pdf"], listed_names
    # Every name in frontmatter must exist on disk
    listed_names.each do |name|
      assert_path_exists File.join(att_dir, name),
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

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")
    stem = File.basename(result.path, ".md")
    att_dir = File.join(@tmpdir, "attachments", stem)

    content = File.read(result.path)
    frontmatter = YAML.safe_load(content.split("---\n")[1])
    listed_names = frontmatter["attachments"]

    assert_equal %w[file.pdf file-2.pdf], listed_names
    listed_names.each do |name|
      assert_path_exists File.join(att_dir, name),
                         "frontmatter attachment '#{name}' should exist on disk"
    end
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

    result1 = @normalizer.normalize(path1, account: "personal", folder: "INBOX")
    result2 = @normalizer.normalize(path2, account: "personal", folder: "INBOX")

    assert result1, "first normalization should succeed"
    assert_nil result2, "second normalization should be skipped"
  end

  def test_collision_suffix_on_filename_clash
    eml1 = build_eml(from: "a@example.com", to: "b@example.com", subject: "Same Subject", body: "first",
                     message_id: "msg1@example.com")
    eml2 = build_eml(from: "a@example.com", to: "b@example.com", subject: "Same Subject", body: "second",
                     message_id: "msg2@example.com")
    # Set same date so timestamps match
    path1 = write_eml(eml1, "msg1.eml")
    path2 = write_eml(eml2, "msg2.eml")

    result1 = @normalizer.normalize(path1, account: "personal", folder: "INBOX")
    result2 = @normalizer.normalize(path2, account: "personal", folder: "INBOX")

    assert result1
    assert result2
    refute_equal result1.path, result2.path
    # One should have a suffix
    stems = [File.basename(result1.path, ".md"), File.basename(result2.path, ".md")]
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

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")
    stem = File.basename(result.path, ".md")

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

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
    assert_includes content, "Main content."
    refute_includes content, "CEO, Example Corp"
  end

  def test_forwarded_message_extracts_original_info
    eml = build_forwarded_eml(
      forwarder_from: "Jane Doe <jane@example.com>",
      forwarder_to: "inbox@example.net",
      original_from: "Acme Corp <no-reply@acme.example.com>",
      original_to: "<jane@example.com>, <other@example.com>",
      original_date: "Tue, Mar 3, 2026 at 12:31 PM",
      original_subject: "Monthly Invoice",
      body: "Your invoice is attached."
    )
    path = write_eml(eml)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
    frontmatter = YAML.safe_load(content.split("---\n")[1])

    assert_equal "Acme Corp <no-reply@acme.example.com>", frontmatter["from"]
    assert_equal "<jane@example.com>, <other@example.com>", frontmatter["to"]
    assert_equal "Monthly Invoice", frontmatter["subject"]
    assert_match(/\A2026-03-03T12:31:00/, frontmatter["date"])
    assert_match(/Jane Doe <jane@example.com>/, frontmatter["forwarded_by"])
    assert frontmatter["forwarded_date"]
  end

  def test_forwarded_message_strips_header_block
    eml = build_forwarded_eml(
      forwarder_from: "jane@example.com",
      forwarder_to: "inbox@example.net",
      original_from: "sender@example.com",
      original_to: "jane@example.com",
      original_date: "Mon, Mar 2, 2026 at 10:00 AM",
      original_subject: "Test",
      body: "Actual content here."
    )
    path = write_eml(eml)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
    refute_includes content, "Forwarded message"
    refute_includes content, "From: sender@example.com"
    assert_includes content, "Actual content here."
  end

  def test_forwarded_message_slug_uses_original_subject
    eml = build_forwarded_eml(
      forwarder_from: "jane@example.com",
      forwarder_to: "inbox@example.net",
      original_from: "sender@example.com",
      original_to: "jane@example.com",
      original_date: "Mon, Mar 2, 2026 at 10:00 AM",
      original_subject: "Original Topic",
      body: "Content."
    )
    path = write_eml(eml)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert_match(/original-topic\.md\z/, result.path)
  end

  def test_forwarded_message_uses_original_date_in_stem
    eml = build_forwarded_eml(
      forwarder_from: "jane@example.com",
      forwarder_to: "inbox@example.net",
      original_from: "sender@example.com",
      original_to: "jane@example.com",
      original_date: "Mon, Mar 2, 2026 at 10:00 AM",
      original_subject: "Dated Email",
      body: "Content."
    )
    path = write_eml(eml)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert_match(/\A20260302-/, File.basename(result.path))
  end

  def test_forwarded_date_with_narrow_non_breaking_space
    eml = build_forwarded_eml(
      forwarder_from: "jane@example.com",
      forwarder_to: "inbox@example.net",
      original_from: "sender@example.com",
      original_to: "jane@example.com",
      original_date: "Tue, Mar 3, 2026 at 12:31\u202FPM",
      original_subject: "NNBSP Date",
      body: "Content."
    )
    path = write_eml(eml)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
    frontmatter = YAML.safe_load(content.split("---\n")[1])
    assert_match(/\A2026-03-03T12:31:00/, frontmatter["date"])
  end

  def test_forwarded_message_with_attachments
    eml = build_forwarded_eml(
      forwarder_from: "jane@example.com",
      forwarder_to: "inbox@example.net",
      original_from: "billing@example.com",
      original_to: "jane@example.com",
      original_date: "Wed, Mar 4, 2026 at 9:00 AM",
      original_subject: "Invoice",
      body: "See attached.",
      attachments: [{ name: "invoice.pdf", content: "fake pdf" }]
    )
    path = write_eml(eml)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
    frontmatter = YAML.safe_load(content.split("---\n")[1])
    assert_equal ["invoice.pdf"], frontmatter["attachments"]
    assert_equal "billing@example.com", frontmatter["from"]
    assert frontmatter["forwarded_by"]
  end

  def test_converts_pdf_attachments_to_markdown
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "PDF Convert",
      body: "See attached.",
      attachments: [{ name: "report.pdf", content: "fake pdf content" }]
    )
    path = write_eml(eml)

    # Stub markitdown by putting a script on PATH that writes a .md file
    stub_bin = File.join(@tmpdir, "bin")
    FileUtils.mkdir_p(stub_bin)
    File.write(File.join(stub_bin, "markitdown"), <<~SH)
      #!/bin/sh
      # Write markdown output to the -o target
      shift  # skip input file
      shift  # skip -o flag
      echo "# Converted PDF" > "$1"
    SH
    File.chmod(0o755, File.join(stub_bin, "markitdown"))

    with_path_prepend(stub_bin) do
      result = @normalizer.normalize(path, account: "personal", folder: "INBOX")
      stem = File.basename(result.path, ".md")
      att_dir = File.join(@tmpdir, "attachments", stem)

      assert_path_exists File.join(att_dir, "report.pdf.md"),
                         "markitdown should create report.pdf.md"
      assert_includes File.read(File.join(att_dir, "report.pdf.md")), "Converted PDF"
    end
  end

  def test_skips_markitdown_for_non_pdf_attachments
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "Non PDF",
      body: "See attached.",
      attachments: [{ name: "image.png", content: "fake png" }]
    )
    path = write_eml(eml)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")
    stem = File.basename(result.path, ".md")
    att_dir = File.join(@tmpdir, "attachments", stem)

    refute_path_exists File.join(att_dir, "image.png.md"),
                       "should not create .md for non-PDF attachments"
  end

  def test_handles_markitdown_failure_gracefully
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "Bad PDF",
      body: "See attached.",
      attachments: [{ name: "broken.pdf", content: "not a pdf" }]
    )
    path = write_eml(eml)

    # Stub markitdown that always fails
    stub_bin = File.join(@tmpdir, "bin")
    FileUtils.mkdir_p(stub_bin)
    File.write(File.join(stub_bin, "markitdown"), <<~SH)
      #!/bin/sh
      exit 1
    SH
    File.chmod(0o755, File.join(stub_bin, "markitdown"))

    with_path_prepend(stub_bin) do
      result = @normalizer.normalize(path, account: "personal", folder: "INBOX")
      # Should still succeed — markitdown failure is non-fatal
      assert result
      assert_equal ["broken.pdf"], result.attachments
    end
  end

  def test_non_forwarded_message_has_no_forwarding_fields
    eml = build_eml(
      from: "alice@example.com",
      to: "bob@example.com",
      subject: "Regular Email",
      body: "Just a normal message."
    )
    path = write_eml(eml)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
    frontmatter = YAML.safe_load(content.split("---\n")[1])
    assert_nil frontmatter["forwarded_by"]
    assert_nil frontmatter["forwarded_date"]
  end

  def test_auto_forwarded_message_with_x_forwarded_headers
    mail = Mail.new do
      from    "Original Sender <sender@example.com>"
      to      "recipient@example.com"
      subject "Auto Forwarded"
      body    "This was auto-forwarded."
    end
    mail["X-Forwarded-For"] = "recipient@example.com"
    mail["X-Forwarded-To"] = "inbox@example.net"
    path = write_eml(mail.to_s)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
    frontmatter = YAML.safe_load(content.split("---\n")[1])

    assert_match(/Original Sender/, frontmatter["from"])
    assert_match(/recipient@example\.com/, frontmatter["to"])
    assert_equal "Auto Forwarded", frontmatter["subject"]
    assert_equal "recipient@example.com", frontmatter["forwarded_by"]
    assert_nil frontmatter["forwarded_date"]
    assert_includes content, "This was auto-forwarded."
  end

  def test_manual_forward_takes_priority_over_header_forwarding
    fwd_body = "---------- Forwarded message ---------\n" \
               "From: original@example.com\n" \
               "Date: Mon, Mar 2, 2026 at 10:00 AM\n" \
               "Subject: Original\n" \
               "To: middle@example.com\n" \
               "\n" \
               "The content."

    mail = Mail.new do
      from    "middle@example.com"
      to      "inbox@example.net"
      subject "Fwd: Original"
      body    fwd_body
    end
    mail["X-Forwarded-For"] = "some-other@example.com"
    path = write_eml(mail.to_s)

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    content = File.read(result.path)
    frontmatter = YAML.safe_load(content.split("---\n")[1])

    assert_equal "original@example.com", frontmatter["from"]
    assert_match(/middle@example\.com/, frontmatter["forwarded_by"])
  end

  def test_falls_back_to_raw_body_on_encoding_error
    eml = build_eml(
      from: "a@example.com",
      to: "b@example.com",
      subject: "Encoding Test",
      body: "fallback body text"
    )
    path = write_eml(eml)

    # Inject a mail reader that returns messages whose decoded raises
    reader = Object.new
    reader.define_singleton_method(:read) do |p|
      msg = Mail.read(p)
      msg.define_singleton_method(:decoded) { raise Mail::UnknownEncodingType, "bad encoding" }
      msg
    end

    normalizer = MailWorkflows::Normalizer.new(@tmpdir, mail_reader: reader)
    result = normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert result
    content = File.read(result.path)
    assert_includes content, "fallback body text"
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

    result = @normalizer.normalize(path, account: "personal", folder: "INBOX")

    assert result
    content = File.read(result.path)
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

  def build_forwarded_eml(
    forwarder_from:, forwarder_to:,
    original_from:, original_to:, original_date:, original_subject:,
    body:, attachments: [], message_id: nil
  )
    fwd_body = "---------- Forwarded message ---------\n" \
               "From: #{original_from}\n" \
               "Date: #{original_date}\n" \
               "Subject: #{original_subject}\n" \
               "To: #{original_to}\n" \
               "\n" +
               body

    mail = Mail.new do
      from    forwarder_from
      to      forwarder_to
      subject "Fwd: #{original_subject}"
      body    fwd_body
    end
    mail.message_id = message_id if message_id
    attachments.each do |a|
      mail.add_file(filename: a[:name], content: a[:content])
    end
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

  def with_path_prepend(dir)
    old_path = ENV.fetch("PATH", nil)
    ENV["PATH"] = "#{dir}:#{old_path}"
    yield
  ensure
    ENV["PATH"] = old_path
  end
end
