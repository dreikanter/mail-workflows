# frozen_string_literal: true

require_relative "test_helper"

class RuleSetTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("rule-set-test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- Loading ---

  def test_loads_no_rules_when_config_missing
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)
    assert_empty rule_set.rules
  end

  def test_loads_no_rules_when_rules_key_missing
    write_config({})
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)
    assert_empty rule_set.rules
  end

  def test_loads_rules_in_definition_order
    write_config("rules" => [
                   { "name" => "first", "match" => { "from" => "a@a.com" },
                     "handler" => { "type" => "script", "command" => "true" } },
                   { "name" => "second", "match" => { "from" => "b@b.com" },
                     "handler" => { "type" => "script", "command" => "true" } }
                 ])

    rule_set = MailWorkflows::RuleSet.new(@tmpdir)
    assert_equal %w[first second], rule_set.rules.map(&:name)
  end

  def test_loads_rule_fields
    write_rule(name: "test-rule",
               match: { "from" => "sender@example.com" },
               handler: { "type" => "script", "command" => "/bin/echo" },
               notify: [{ "type" => "desktop" }])

    rule_set = MailWorkflows::RuleSet.new(@tmpdir)
    rule = rule_set.rules.first

    assert_equal "test-rule", rule.name
    assert_equal({ "from" => "sender@example.com" }, rule.match)
    assert_equal "script", rule.handler["type"]
    assert_equal 1, rule.notify.size
  end

  # --- Substring matching ---

  def test_matches_from_substring
    write_rule(name: "test", match: { "from" => "bank.com" })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)

    result = rule_set.match({ "from" => "statements@bank.com", "subject" => "Statement" }, "body")
    assert_equal "test", result.name
  end

  def test_no_match_when_substring_absent
    write_rule(name: "test", match: { "from" => "bank.com" })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)

    result = rule_set.match({ "from" => "other@example.com", "subject" => "Hi" }, "body")
    assert_nil result
  end

  def test_matches_subject_substring
    write_rule(name: "test", match: { "subject" => "invoice" })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)

    result = rule_set.match({ "from" => "a@b.com", "subject" => "Your invoice is ready" }, "")
    assert_equal "test", result.name
  end

  def test_matches_anywhere_substring
    write_rule(name: "test", match: { "anywhere" => "payment confirmed" })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)

    result = rule_set.match({ "from" => "a@b.com", "subject" => "Receipt" }, "Your payment confirmed.")
    assert_equal "test", result.name
  end

  # --- Regex matching ---

  def test_matches_from_regex
    write_rule(name: "test", match: { "from" => '/statements@(mega|other)bank\.com/' })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)

    result = rule_set.match({ "from" => "statements@megabank.com", "subject" => "Statement" }, "")
    assert_equal "test", result.name
  end

  def test_matches_regex_case_insensitive
    write_rule(name: "test", match: { "subject" => "/monthly statement/i" })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)

    result = rule_set.match({ "from" => "a@b.com", "subject" => "Monthly Statement - Feb" }, "")
    assert_equal "test", result.name
  end

  def test_regex_no_match
    write_rule(name: "test", match: { "from" => "/^admin@/" })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)

    result = rule_set.match({ "from" => "user@admin.com", "subject" => "" }, "")
    assert_nil result
  end

  # --- AND logic ---

  def test_all_criteria_must_match
    write_rule(name: "test", match: { "from" => "bank.com", "subject" => "statement" })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)

    # from matches but subject doesn't
    result = rule_set.match({ "from" => "noreply@bank.com", "subject" => "Welcome" }, "")
    assert_nil result

    # both match
    result = rule_set.match({ "from" => "noreply@bank.com", "subject" => "Your statement" }, "")
    assert_equal "test", result.name
  end

  # --- First match wins ---

  def test_first_match_wins
    write_rule(name: "first", match: { "from" => "bank.com" })
    write_rule(name: "second", match: { "from" => "bank.com" })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)

    result = rule_set.match({ "from" => "noreply@bank.com", "subject" => "" }, "")
    assert_equal "first", result.name
  end

  # --- Rule name validation ---

  def test_rejects_rule_with_path_traversal_name
    write_rule(name: "../../etc", match: { "from" => "a@b.com" })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)
    assert_empty rule_set.rules
  end

  def test_rejects_rule_with_slash_in_name
    write_rule(name: "foo/bar", match: { "from" => "a@b.com" })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)
    assert_empty rule_set.rules
  end

  def test_accepts_rule_with_valid_name_characters
    write_rule(name: "bank-statements_v2.1", match: { "from" => "a@b.com" })
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)
    assert_equal 1, rule_set.rules.size
  end

  # --- Invalid rule files ---

  def test_raises_on_rule_missing_name
    write_config("rules" => [{ "match" => {}, "handler" => { "type" => "script" } }])

    assert_raises(KeyError) do
      MailWorkflows::RuleSet.new(@tmpdir)
    end
  end

  def test_raises_on_rule_missing_handler
    write_config("rules" => [{ "name" => "test", "match" => {} }])

    assert_raises(KeyError) do
      MailWorkflows::RuleSet.new(@tmpdir)
    end
  end

  def test_raises_on_invalid_yaml_syntax
    File.write(File.join(@tmpdir, "config.yml"), "rules:\n  - name: test\n    broken: indentation\n foo")

    assert_raises(Psych::SyntaxError) do
      MailWorkflows::RuleSet.new(@tmpdir)
    end
  end

  # --- Empty match ---

  def test_empty_match_never_matches
    write_rule(name: "test", match: {})
    rule_set = MailWorkflows::RuleSet.new(@tmpdir)

    result = rule_set.match({ "from" => "a@b.com", "subject" => "Hi" }, "body")
    assert_nil result
  end

  private

  def write_rule(name:, match:, handler: { "type" => "script", "command" => "true" }, notify: [])
    config_path = File.join(@tmpdir, "config.yml")
    config = File.exist?(config_path) ? (YAML.safe_load_file(config_path) || {}) : {}
    config["rules"] ||= []
    config["rules"] << { "name" => name, "match" => match, "handler" => handler, "notify" => notify }
    File.write(config_path, YAML.dump(config))
  end

  def write_config(data)
    File.write(File.join(@tmpdir, "config.yml"), YAML.dump(data))
  end
end
