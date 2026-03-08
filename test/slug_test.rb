# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/slug"

class SlugTest < Minitest::Test
  def test_simple_subject
    assert_equal "invoice-from-acme", MailWorkflows::Slug.slugify("Invoice from Acme")
  end

  def test_strips_punctuation
    assert_equal "hello-world", MailWorkflows::Slug.slugify("Hello, World!")
  end

  def test_collapses_whitespace_and_hyphens
    assert_equal "a-b-c", MailWorkflows::Slug.slugify("  a   b   c  ")
  end

  def test_empty_subject
    assert_equal "no-subject", MailWorkflows::Slug.slugify("")
  end

  def test_nil_subject
    assert_equal "no-subject", MailWorkflows::Slug.slugify(nil)
  end

  def test_whitespace_only_subject
    assert_equal "no-subject", MailWorkflows::Slug.slugify("   ")
  end

  def test_transliterates_latin_diacritics
    assert_equal "cafe-resume", MailWorkflows::Slug.slugify("Café Résumé")
  end

  def test_transliterates_cyrillic
    assert_equal "privet-mir", MailWorkflows::Slug.slugify("Привет Мир")
  end

  def test_transliterates_german
    assert_equal "grusse-aus-munchen", MailWorkflows::Slug.slugify("Grüße aus München")
  end

  def test_truncates_long_subject_at_word_boundary
    long_subject = "this is a very long subject line that should be truncated at approximately sixty characters on a word boundary"
    slug = MailWorkflows::Slug.slugify(long_subject)
    assert slug.length <= 65, "slug too long: #{slug.length}"
    refute slug.end_with?("-"), "slug should not end with hyphen"
  end

  def test_short_subject_not_truncated
    subject = "short"
    assert_equal "short", MailWorkflows::Slug.slugify(subject)
  end

  def test_numbers_preserved
    assert_equal "order-12345", MailWorkflows::Slug.slugify("Order #12345")
  end

  def test_transliterates_russian
    assert_equal "ezhemesyachnyj-otchyot-po-prodazham-za-fevral",
                 MailWorkflows::Slug.slugify("Ежемесячный отчёт по продажам за февраль")
  end

  def test_transliterates_serbian_cyrillic
    assert_equal "dobro-doshli-u-beograd", MailWorkflows::Slug.slugify("Добро дошли у Београд")
  end

  def test_transliterates_serbian_latin
    assert_equal "dobro-dosli-u-beograd", MailWorkflows::Slug.slugify("Dobro došli u Beograd")
  end

  def test_transliterates_turkish
    assert_equal "turkce-ozellikleri-guncellendi",
                 MailWorkflows::Slug.slugify("Türkçe özellikleri güncellendi")
  end

  def test_transliterates_spanish
    assert_equal "factura-numero-senor-garcia",
                 MailWorkflows::Slug.slugify("Factura número señor García")
  end
end
