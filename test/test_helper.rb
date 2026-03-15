# frozen_string_literal: true

# Suppress "statement not reached" warnings from the mail gem's generated parsers
$VERBOSE = nil

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mail_workflows"

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "shellwords"
require "yaml"
