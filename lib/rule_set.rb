# frozen_string_literal: true

require "yaml"

module MailWorkflows
  # A single rule loaded from the rules section of config.yml.
  Rule = Struct.new(:name, :match, :handler, :notify)

  # Loads rules from config.yml and matches them against normalized emails.
  # Rules are evaluated in definition order; first match wins.
  class RuleSet
    attr_reader :rules

    def initialize(home, logger: NULL_LOGGER)
      @home = home
      @logger = logger
      @rules = load_rules
    end

    # Returns the first matching Rule for the given frontmatter and body, or nil.
    def match(frontmatter, body)
      full_text = "#{frontmatter_text(frontmatter)}\n#{body}"

      rules.each do |rule|
        if matches_rule?(rule, frontmatter, body, full_text)
          @logger.info "rule matched: #{rule.name}"
          return rule
        end
      end

      nil
    end

    private

    def load_rules
      config_path = File.join(@home, "config.yml")
      return [] unless File.exist?(config_path)

      config = YAML.safe_load_file(config_path, permitted_classes: [Symbol])
      entries = config&.fetch("rules", nil) || []

      entries.filter_map do |data|
        name = data.fetch("name")

        unless valid_rule_name?(name)
          @logger.error "invalid rule name #{name.inspect}, skipping"
          next
        end

        Rule.new(
          name: name,
          match: data.fetch("match", {}),
          handler: data.fetch("handler"),
          notify: data.fetch("notify", [])
        )
      end
    end

    def valid_rule_name?(name)
      name.is_a?(String) && name.match?(/\A[a-zA-Z0-9_][a-zA-Z0-9._-]*\z/)
    end

    def matches_rule?(rule, frontmatter, _body, full_text)
      criteria = rule.match
      return false if criteria.nil? || criteria.empty?

      criteria.all? do |field, pattern|
        case field
        when "from"     then matches?(frontmatter["from"].to_s, pattern)
        when "subject"  then matches?(frontmatter["subject"].to_s, pattern)
        when "anywhere" then matches?(full_text, pattern)
        else
          @logger.warn "unknown match field: #{field} in rule #{rule.name}"
          false
        end
      end
    end

    def matches?(text, pattern)
      regex = parse_pattern(pattern)
      regex ? text.match?(regex) : text.include?(pattern)
    rescue Regexp::TimeoutError
      @logger.error "regex timed out for pattern: #{pattern}"
      false
    end

    # Parses /pattern/flags syntax into a Regexp, or returns nil for plain strings.
    def parse_pattern(pattern)
      m = pattern.match(%r{\A/(.*)/([imx]*)\z}m)
      return nil unless m

      flags = 0
      flags |= Regexp::IGNORECASE if m[2].include?("i")
      flags |= Regexp::MULTILINE if m[2].include?("m")
      flags |= Regexp::EXTENDED if m[2].include?("x")
      Regexp.new(m[1], flags, timeout: 1)
    end

    def frontmatter_text(frontmatter)
      frontmatter.map { |k, v| "#{k}: #{v}" }.join("\n")
    end
  end
end
