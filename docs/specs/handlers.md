# Mail Handlers — Design Spec (Working Draft)

## Overview

Handlers are the processing layer that runs after email normalization. Each
incoming email is matched against a set of rules. When a rule matches, its
handler processes the email and optionally sends notifications.

```
[normalized .md] → [rule match] → [preprocess] → [handler] → [notify]
```

## Rules

A rule is a YAML file in `$MAIL_WORKFLOWS_HOME/rules/`. It defines:

- **`name`** — unique identifier, also scopes the handler's persistent state
  directory
- **`match`** — criteria to test against the normalized email
- **`handler`** — what to run when the rule matches
- **`notify`** — optional list of notification channels

Rules are evaluated in filename order. First match wins.

### Match Criteria

Match fields are tested against the normalized markdown frontmatter and body.
All specified fields must match (AND logic). Omitted fields are not tested.

| Field | Matches against | Syntax |
|-------|----------------|--------|
| `from` | frontmatter `from` | substring or `/regex/flags` |
| `subject` | frontmatter `subject` | substring or `/regex/flags` |
| `anywhere` | full text (frontmatter + body) | substring or `/regex/flags` |

Regex values are delimited with `/pattern/flags` (e.g., `/monthly statement/i`).
Plain strings are substring matches.

### Example Rule

```yaml
# ~/.mail-workflows/rules/bank-statements.yml
name: bank-statements

match:
  from: '/statements@(megabank|otherbank)\.com/'
  subject: '/monthly statement/i'

handler:
  type: llm
  model: claude-haiku-4-5-20251001
  prompt: bank-statement

notify:
  - type: telegram
  - type: email
    to: user@gmail.com
```

## Preprocessing

Preprocessing is automatic and identical for all emails — not configurable
per rule.

After normalization, if an email has PDF attachments, each PDF is converted
to Markdown using [MarkItDown](https://github.com/microsoft/markitdown)
(`pip install 'markitdown[pdf]'`). The converted text is stored alongside
the attachment and included in the handler input as `preprocessed` content.

Future preprocessing steps (OCR, other document types) follow the same
pattern: run eagerly on all emails, make results available to handlers.

## Handler Interface

### Input

Handlers receive a JSON document on stdin:

```json
{
  "email": {
    "message_id": "<abc@example.com>",
    "from": "statements@megabank.com",
    "to": "user@gmail.com",
    "subject": "Monthly Statement - February 2026",
    "date": "2026-03-01T08:00:00+00:00",
    "folder": "INBOX",
    "body": "... normalized markdown body ...",
    "attachments": ["statement.pdf"],
    "attachment_dir": "/home/user/.mail-workflows/attachments/20260301-080000_monthly-statement"
  },
  "preprocessed": {
    "statement.pdf": "... markdown extracted from PDF ..."
  },
  "state_dir": "/home/user/.mail-workflows/state/bank-statements",
  "config": {
    "model": "claude-haiku-4-5-20251001"
  }
}
```

- **`email`** — parsed frontmatter fields plus body text
- **`preprocessed`** — map of attachment filename → extracted markdown
  (empty `{}` when no preprocessed content)
- **`state_dir`** — writable directory for handler-specific persistence
  (created automatically, never touched by the core tool)
- **`config`** — handler-specific settings from the rule YAML

### Output

Handlers write a JSON document to stdout:

```json
{
  "summary": "Feb 2026 statement: $4,230 spent, net worth $52,100 → $48,900",
  "body": "## Monthly Report\n\n...",
  "data": {}
}
```

- **`summary`** — one-line summary for notifications
- **`body`** — detailed content (for email notifications, saved output)
- **`data`** — arbitrary structured data for handler-specific use

**Exit code:** 0 = success, non-zero = failure (email stays in `new/` for
retry on next run).

### Output Persistence

Handler output is saved to `state_dir` automatically by the core tool as
`<timestamp>_<slug>.json`. This serves as both the artifact log and the
source for notifications. Handlers can read/write additional files in
`state_dir` for their own bookkeeping (e.g., previous month's data for
comparison).

## Handler Types

### `type: llm` — Claude Code Non-Interactive

Calls `claude -p` with an assembled prompt. This is the default handler type
for most use cases — summarization, extraction, classification, analysis.

```yaml
handler:
  type: llm
  model: claude-haiku-4-5-20251001    # optional, defaults to project default
  prompt: bank-statement               # references prompts/<name>.md
  tools:                               # optional, restricts available tools
    - Read
    - Grep
    - Bash
```

The prompt template is a Markdown file in `$MAIL_WORKFLOWS_HOME/prompts/`
with placeholders:

- `{{EMAIL_CONTENT}}` — the normalized email body
- `{{PREPROCESSED}}` — concatenated preprocessed attachment text
- `{{STATE_DIR}}` — path to the handler's state directory

Implementation runs:

```bash
claude -p --model <model> [--tools "<tools>"] --output-format json "prompt"
```

The assembled prompt (template + email content + preprocessed text) is passed
as the prompt argument. The prompt should instruct the model to produce the
standard output JSON format.

For simple single-turn tasks, `tools` can be omitted or set to an empty list
to disable tool use. For tasks requiring file access or multi-step reasoning,
include the relevant tools.

**Extensibility:** the `command` field can be added later to swap `claude`
for a different agent CLI (e.g., `aider`, `goose`, a custom wrapper). Any
CLI that reads a prompt and writes output to stdout works.

### `type: script` — Arbitrary Executable

For automations unrelated to LLM, or for full custom control.

```yaml
handler:
  type: script
  command: handlers/track-payment      # relative to tool repo, or absolute
```

The script receives the full handler input JSON on stdin and writes handler
output JSON to stdout. It can be written in any language.

**When to use:** non-LLM automations, integrations with external APIs,
or cases where you need full control over the processing logic.

## Notifications

Notification channels are configured in `accounts.yml` under `notifications`.
Each rule can trigger multiple channels.

### Built-in Notifiers

| Type | Config source | Sends |
|------|--------------|-------|
| `email` | `accounts.yml → notifications.email` | Summary + body via SMTP |
| `telegram` | `accounts.yml → notifications.telegram` | Summary via Bot API |
| `desktop` | none | macOS notification via `osascript` |

Notifiers receive the handler's JSON output plus email metadata (from,
subject, date, rule name).

Per-rule overrides are supported as notifier properties:

```yaml
notify:
  - type: email
    to: special@example.com    # overrides default recipient
  - type: telegram
```

## State and Persistence

Each rule gets a dedicated directory:

```
~/.mail-workflows/state/<rule-name>/
```

This directory holds:

- **Handler output** — saved automatically as `<timestamp>_<slug>.json`
- **Handler working data** — any files the handler reads/writes for its
  own purposes (e.g., `last_month.json` for month-over-month comparison,
  `payments.csv` for tracking confirmed payments)

The core tool creates the directory and saves handler output. Everything
else in the directory is the handler's responsibility. No database, no
schema — just files.

## Processing Pipeline

Integrated into `mw run`, after normalization:

```
for each .md in normalized/<account>/new/:
  1. Parse frontmatter
  2. Find first matching rule (filename order)
  3. If no match → move to processed/
  4. Load preprocessed content (PDF→Markdown results, if any)
  5. Build handler input JSON
  6. Execute handler (llm / agent / script)
  7. On failure (non-zero exit):
       increment retry count, skip
       after 3 failures → move to failed/
  8. On success:
       save output to state/<rule>/
       run each notifier
       move .md to processed/
```

Retry tracking: a sidecar file `<message>.retries` next to the `.md`,
containing the failure count as a plain integer.

## Directory Layout (additions)

```
~/.mail-workflows/
  state/                         # per-handler persistent state + output
    bank-statements/
      20260301-080000_monthly-statement.json
      last_month.json
    payment-tracker/
      payments.csv

mail-workflows/                  # tool repo
  lib/
    rule_matcher.rb              # rule loading, matching logic
    handler_runner.rb            # handler dispatch (llm/agent/script)
    preprocessor.rb              # PDF→Markdown conversion
    notifier.rb                  # notification dispatch
  handlers/                      # shipped example handler scripts
    track-payment
  docs/
    specs/
      handlers.md                # this file
```

## Dependencies (new)

| Dependency | Purpose | Install |
|-----------|---------|---------|
| MarkItDown | PDF → Markdown | `pip install 'markitdown[pdf]'` |
| Claude Code | `type: llm` handlers | `npm install -g @anthropic-ai/claude-code` |

## Open Questions

- **Default model:** project-wide default model setting in `accounts.yml`
  (or a separate `config.yml`)?
- **Prompt template format:** is `{{placeholder}}` sufficient, or do we
  need conditional sections / loops?
- **Batch processing:** should handlers receive one email at a time, or
  optionally a batch (e.g., "here are 5 new bank statements")?
- **Notification formatting:** should the handler or the notifier own
  message formatting (Telegram Markdown, HTML email, etc.)?
- **Claude Code system prompt:** `--system-prompt` can replace the built-in
  prompt, but stripping it removes tool use capabilities. Worth testing
  whether `--tools ""` alone is sufficient to reduce token overhead for
  simple single-turn tasks.
