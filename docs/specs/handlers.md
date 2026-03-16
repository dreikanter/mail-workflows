# Mail Handlers — Design Spec (Working Draft)

## Overview

Handlers are the processing layer that runs after email normalization. Each
incoming email is matched against a set of rules. When a rule matches, its
handler processes the email and optionally sends notifications.

```
[normalized .md] → [rule match] → [handler] → [notify]
```

## Rules

A rule is defined in the `rules` section of `config.yml`. It specifies:

- **`name`** — unique identifier, also scopes the handler's persistent state
  directory
- **`match`** — criteria to test against the normalized email
- **`handler`** — what to run when the rule matches
- **`notify`** — optional list of notification channels

Rules are evaluated in definition order. First match wins.

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
# In ~/.mail-workflows/config.yml
rules:
  - name: bank-statements
    match:
      from: '/statements@(megabank|otherbank)\.com/'
      subject: '/monthly statement/i'
    handler:
      type: llm
      model: haiku
      prompt: bank-statement
    notify:
      - type: telegram
      - type: email
        to: user@gmail.com
```

## Handler Interface

### Input

Script handlers receive a JSON document on stdin (LLM handlers receive
context via the assembled prompt instead):

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
    "model": "haiku"
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

**Exit code:** 0 = success, non-zero = failure (email moves to `failed/`).

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
  model: haiku           # optional, defaults to project default
  prompt: bank-statement # references prompts.<name> in config.yml
```

The prompt template is defined in the `prompts` section of `config.yml`
with `{{placeholder}}` substitution:

- `{{EMAIL_CONTENT}}` — the normalized email body
- `{{PREPROCESSED}}` — concatenated preprocessed attachment text

The core tool assembles the prompt, then runs:

```bash
cd "$STATE_DIR" && claude -p \
  --model <model> \
  --allowedTools "Read,Write" \
  --add-dir "$ATTACHMENT_DIR" \
  --output-format json \
  "assembled prompt"
```

The agent runs with its working directory set to the handler's state
directory and can read/write files there for persistence (e.g., saving
last month's data for comparison). Access to the attachment directory
is granted read-only via `--add-dir`. The `--allowedTools` restriction
prevents shell access and limits the agent to file operations.

The prompt should instruct the model to produce the standard output JSON
format. It can also instruct the model to read/write state files as needed.

**Extensibility:** the `command` field can be added later to swap `claude`
for a different agent CLI (e.g., `aider`, `goose`). Any CLI that reads a
prompt and writes output to stdout works.

### `type: script` — Arbitrary Executable

For automations unrelated to LLM, or for full custom control.

```yaml
handler:
  type: script
  command: handlers/track-payment      # relative to $MAIL_WORKFLOWS_HOME, or absolute
```

The script receives the full handler input JSON on stdin and writes handler
output JSON to stdout. It can be written in any language.

**When to use:** non-LLM automations, integrations with external APIs,
or cases where you need full control over the processing logic.

## Notifications

Notification channels are configured in `config.yml` under `notifications`.
Each rule can trigger multiple channels.

### Built-in Notifiers

| Type | Config source | Sends |
|------|--------------|-------|
| `email` | `config.yml → notifications.email` | Summary + body via SMTP |
| `telegram` | `config.yml → notifications.telegram` | Summary via Bot API |
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
  4. Build handler input JSON (includes preprocessed PDF content from attachments/)
  5. Execute handler (llm / script)
  6. On failure (non-zero exit): move to failed/
  7. On success:
       save output to state/<rule>/
       run each notifier
       move .md to processed/
```

## Directory Layout (additions to user data)

```
~/.mail-workflows/
  state/                         # per-handler persistent state + output
    bank-statements/
      20260301-080000_monthly-statement.json
      last_month.json
    payment-tracker/
      payments.csv
```

## Design Decisions

- **Default model** is configured in `config.yml`. One `--path` = one
  configuration.
- **Prompt templates** use simple `{{placeholder}}` substitution.
- **Handlers process one email at a time** (no batching).
- **Notification formatting** is owned by the handler — notifiers send
  the handler's output as-is.
- **Claude Code system prompt** is kept as-is (default). Tool access is
  controlled via `--allowedTools`.
