# Mail Workflows — Architecture Spec

## Overview

An automated system that syncs email from IMAP servers to local Maildir
storage, then runs configurable processing pipelines on incoming emails,
producing artifacts and notifications.

## Design Principles

- **Maildir as the source of truth.** Each email is a file. No databases.
  State tracking uses Maildir's own `new/` → `cur/` convention.
- **Cron as the scheduler.** No long-running daemons. A single cron entry
  runs sync + process. Missed runs just mean a bigger batch next time.
- **Repo = config.** The git repo contains all scripts, rules, and prompt
  templates. Clone it, add credentials, add one cron line, done.
- **Unix philosophy.** Small composable scripts. Shell for orchestration,
  Ruby for email parsing and processing logic.

## High-Level Flow

```
cron (every N minutes)
  +-- run
      +-- 1. acquire lock (flock, skip if already running)
      +-- 2. sync: mbsync pulls new mail → Maildir new/
      +-- 3. process: for each .eml in new/
              +-- match against rules (from, subject regex)
              +-- preprocess (extract PDF text, strip HTML, etc.)
              +-- handle: run script or LLM with matched prompt
              +-- deliver artifacts / send notifications
              +-- move .eml to cur/ (marks as processed)
```

After downtime, cron fires, mbsync fetches all accumulated mail, and the
processor handles the entire batch. No special catch-up logic needed — this
falls out naturally from Maildir semantics.

## Directory Layout

```
mail-workflows/
+-- bin/
|   +-- run                # Entry point (lock → sync → process)
|   +-- sync               # Wraps mbsync
|   +-- process            # Core processor loop
+-- config/
|   +-- accounts.yml       # IMAP account settings (gitignored)
|   +-- accounts.yml.example
|   +-- rules/             # One YAML per rule
|       +-- bank-statements.yml
|       +-- bank-notifications.yml
+-- prompts/
|   +-- bank-statement.md
|   +-- bank-notification.md
+-- preprocessors/         # Small scripts, each does one thing
|   +-- extract-pdf-text   # PDF attachment → plain text
|   +-- strip-html         # HTML body → plain text
|   +-- extract-headers    # Emit structured header summary
+-- handlers/              # Post-processing / notification scripts
|   +-- save-artifact      # Write output to artifacts/
|   +-- notify-desktop     # macOS desktop notification
|   +-- notify-telegram    # Send Telegram message
|   +-- notify-email       # Send email notification
+-- data/                  # gitignored
|   +-- mail/              # Maildir storage
|   |   +-- <account>/
|   |       +-- new/       # Unprocessed emails
|   |       +-- cur/       # Processed emails
|   |       +-- tmp/       # Maildir temp (used by mbsync)
|   +-- artifacts/         # Generated outputs
|   +-- logs/              # Run logs
+-- .mbsyncrc.template     # Template, rendered from accounts.yml
+-- setup                  # One-time setup script
```

## Component Details

### Mail Sync — mbsync (isync)

**Why mbsync:**
- Battle-tested, actively maintained, available via Homebrew and apt
- Native Maildir support — each message becomes a separate file
- Works with any IMAP server (Gmail, Fastmail, self-hosted, etc.)
- Idempotent: re-running after downtime just downloads what's new
- Supports multiple accounts

**Config:** `.mbsyncrc` is generated from `config/accounts.yml` by the setup
script. This keeps credentials out of the repo while making the config
reproducible.

### Account Configuration

```yaml
# config/accounts.yml.example
accounts:
  personal:
    host: imap.gmail.com
    port: 993
    user: user@gmail.com
    pass_cmd: "security find-generic-password -s mail-workflows-personal -w"
    tls: true
    folders:
      - INBOX
  work:
    host: imap.fastmail.com
    port: 993
    user: user@fastmail.com
    pass_cmd: "security find-generic-password -s mail-workflows-work -w"
    tls: true
    folders:
      - INBOX
      - Receipts
```

Passwords are retrieved via an external command (`pass_cmd`), not stored in
the config file. On macOS, use Keychain. On Linux, use `pass`, `secret-tool`,
or a similar credential store.

### Processing Rules — YAML

```yaml
# config/rules/bank-statements.yml
name: bank-statements
match:
  from: '/statements@(megabank|otherbank)\.com/'
  subject: '/monthly statement/i'
  has_attachment: "*.pdf"
preprocess:
  - extract-pdf-text
handler:
  type: llm
  model: claude-sonnet-4-20250514
  prompt: bank-statement
notify:
  - save-artifact
  - notify-desktop
  - notify-telegram
```

```yaml
# config/rules/order-confirmations.yml
name: order-confirmations
match:
  from: '/noreply@shop\.example\.com/'
  subject: '/order confirm/i'
preprocess:
  - strip-html
handler:
  type: script
  command: preprocessors/extract-order-info
notify:
  - save-artifact
```

**Match fields:** `from` and `subject` support plain strings (substring
match) or regexes (delimited with `/pattern/flags`).

**Rules** are evaluated in filename order. First match wins.

### Preprocessors

Small standalone scripts. Each reads from stdin or a temp directory of
extracted parts, writes to stdout. They are chained in the order specified
by the rule.

- **`extract-pdf-text`**: Uses `pdftotext` (poppler-utils) to convert PDF
  attachments to plain text.
- **`strip-html`**: Converts HTML email body to plain text.
- **`extract-headers`**: Emits a structured summary (From, To, Date, Subject).

### Handlers

Each rule specifies a handler — either an LLM call or a plain script. The
handler receives preprocessed email content and produces structured output.

**LLM handler** (`type: llm`):
- Calls the Anthropic API with the referenced prompt template
- Model is configurable per rule
- Prompt template is a Markdown file with `{{EMAIL_CONTENT}}` placeholder

```markdown
# prompts/bank-statement.md
You are analyzing a bank statement. Extract:
- Statement period
- Opening balance, closing balance
- Total deposits, total withdrawals
- Number of transactions
- Any unusual transactions (>$1000 or flagged)

Output as JSON.

---
{{EMAIL_CONTENT}}
```

**Script handler** (`type: script`):
- Runs a local script with preprocessed content on stdin
- Script writes structured output to stdout

Both handler types must produce output in a standardized format:

```json
{
  "summary": "One-line summary for notifications",
  "body": "Detailed content (for artifacts, longer notifications)",
  "data": { "...arbitrary structured data..." }
}
```

The `summary` field is used by notification scripts. The `body` and `data`
fields are written to artifacts.

### Notifications

Each rule can trigger multiple notification channels. Notification scripts
receive the handler's JSON output on stdin plus metadata via environment
variables (`$RULE_NAME`, `$EMAIL_FROM`, `$EMAIL_SUBJECT`, `$EMAIL_DATE`).

- **`save-artifact`**: Writes to `data/artifacts/<rule>/<date>-<subject-slug>.json`
- **`notify-desktop`**: Uses `osascript` on macOS (terminal-notifier as
  fallback), `notify-send` on Linux
- **`notify-telegram`**: Sends message via Telegram Bot API (bot token and
  chat ID from config)
- **`notify-email`**: Sends email via configured SMTP (for forwarding
  summaries to another address)

Notification config (tokens, chat IDs, SMTP settings) lives in
`config/accounts.yml` under a `notifications` key:

```yaml
notifications:
  telegram:
    bot_token_cmd: "security find-generic-password -s mail-workflows-tg -w"
    chat_id: "123456789"
  email:
    smtp_host: smtp.gmail.com
    smtp_port: 587
    smtp_user: user@gmail.com
    smtp_pass_cmd: "security find-generic-password -s mail-workflows-smtp -w"
    from: user@gmail.com
```

## State Management

**No database.** Maildir's `new/` → `cur/` move is atomic (rename on the
same filesystem) and is the only state transition. If processing fails:
- The .eml stays in `new/`
- Next run retries it
- After N consecutive failures on the same message, move it to a `failed/`
  directory and log a warning

Processed emails are kept in `cur/` indefinitely.

A simple lockfile (`flock` on `data/.lock`) prevents concurrent runs.

## Implementation Language

| Layer | Language | Rationale |
|-------|----------|-----------|
| Orchestration (`bin/run`, `bin/sync`) | Shell (bash) | Zero deps, portable, simple glue |
| Email parsing + rule matching (`bin/process`) | Ruby | `mail` gem handles .eml/MIME well |
| Preprocessors | Shell / Ruby | Depends on task complexity |
| LLM wrapper | Ruby | Thin wrapper around Anthropic API |
| Notification scripts | Shell / Ruby | Simple I/O |

## Setup & Deployment

```bash
# 1. Clone
git clone <repo> ~/mail-workflows
cd ~/mail-workflows

# 2. Install dependencies
./setup                    # installs mbsync, pdftotext, ruby gems via brew/apt

# 3. Configure
cp config/accounts.yml.example config/accounts.yml
$EDITOR config/accounts.yml   # add IMAP credentials, notification tokens

# 4. Schedule
# setup script offers to install the cron entry:
#   */5 * * * * /path/to/mail-workflows/bin/run >> /path/to/data/logs/cron.log 2>&1
```

To replicate on another machine: clone repo, run setup, edit accounts.yml.

## Robustness

| Concern | Solution |
|---------|----------|
| Concurrent runs | `flock` on lockfile, second run skips |
| Downtime / missed crons | mbsync fetches all accumulated mail; processor handles batch |
| Processing failure | Email stays in `new/`, retried next run; moved to `failed/` after N retries |
| Partial output | Artifacts written to temp file, renamed atomically on success |
| Credential security | `accounts.yml` is gitignored; passwords via external commands |
| Large attachments | Preprocessors extract text; raw attachments not sent to LLM |
