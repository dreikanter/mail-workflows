# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "yaml"
require "fileutils"
module MailWorkflows
  # Runs claude -p with an assembled prompt template.
  class LlmHandler
    TIMEOUT_SECONDS = 300
    def initialize(home, logger: NULL_LOGGER)
      @home = home
      @logger = logger
    end

    def execute(config, input)
      prompt_name = config.fetch("prompt")
      model = config.fetch("model", default_model)
      prompt_text = assemble_prompt(prompt_name, input)
      state_dir = input.fetch("state_dir")
      attachment_dir = input.dig("email", "attachment_dir")

      FileUtils.mkdir_p(state_dir)

      cmd = build_command(model, attachment_dir)
      @logger.info "llm handler: model=#{model} prompt=#{prompt_name}"

      stdout, stderr, status = Timeout.timeout(TIMEOUT_SECONDS) do
        Open3.capture3(*cmd, stdin_data: prompt_text, chdir: state_dir)
      end

      unless status.success?
        @logger.error "claude exited #{status.exitstatus}: #{stderr}"
        raise "claude failed (exit #{status.exitstatus}): #{stderr.lines.first&.chomp}"
      end

      parse_claude_output(stdout)
    end

    private

    def build_command(model, attachment_dir)
      cmd = ["claude", "-p", "--model", model, "--allowedTools", "Read,Write", "--output-format", "json"]
      cmd += ["--add-dir", attachment_dir] if attachment_dir && Dir.exist?(attachment_dir)
      cmd
    end

    def assemble_prompt(prompt_name, input)
      path = File.join(@home, "prompts", "#{prompt_name}.md")
      raise "prompt template not found: #{path}" unless File.exist?(path)

      template = File.read(path)
      template
        .gsub("{{EMAIL_CONTENT}}", input.dig("email", "body") || "")
        .gsub("{{PREPROCESSED}}", format_preprocessed(input.fetch("preprocessed", {})))
    end

    def format_preprocessed(preprocessed)
      return "" if preprocessed.empty?

      preprocessed.map { |name, content| "## #{name}\n\n#{content}" }.join("\n\n")
    end

    def default_model
      config_path = File.join(@home, "accounts.yml")
      return "sonnet" unless File.exist?(config_path)

      config = YAML.safe_load_file(config_path, permitted_classes: [Symbol]) || {}
      config.fetch("default_model", "sonnet")
    end

    def parse_claude_output(stdout)
      outer = JSON.parse(stdout)
      result_text = outer.fetch("result", stdout)
      parse_handler_json(result_text)
    rescue JSON::ParserError
      parse_handler_json(stdout)
    end

    def parse_handler_json(text)
      # Extract JSON from text (model may include markdown fences)
      json_str = text.match(/\{[\s\S]*\}/)&.to_s
      raise "no JSON found in handler output" unless json_str

      parsed = JSON.parse(json_str)
      validate_output(parsed)
      parsed
    end

    def validate_output(output)
      raise "handler output missing 'summary'" unless output.key?("summary")
    end
  end
end
