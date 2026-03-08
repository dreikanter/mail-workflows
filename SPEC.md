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
- **Tool ≠ data.** The git repo is the tool: scripts, preprocessors,
  handlers. User data and configuration live in a separate directory
  (`~/.mail-workflows/` by default, override with `$MAIL_WORKFLOWS_HOME`).
  The tool is easy to install and update (`git pull`); user data is easy
  to backup and never touches GitHub.
- **Unix philosophy.** Small composable scripts. Shell for orchestration,
  Ruby for email parsing and processing logic.

## High-Level Flow

```
cron (every N minutes)
  +-- run
      +-- 1. acquire lock (flock, skip if already running)
      +-- 2. sync: mbsync pulls new mail → Maildir new/
      +-- 3. normalize: for each .eml in new/
      |       +-- parse MIME (mail gem)
      |       +-- write markdown + YAML frontmatter → normalized/
      |       +-- extract attachments → attachments/
      |       +-- move .eml to cur/ (marks as synced)
      +-- 4. process: for each normalized .md
              +-- match against rules (from, subject regex)
              +-- preprocess (extract PDF text, strip HTML, etc.)
              +-- handle: run script or LLM with matched prompt
              +-- deliver artifacts / send notifications
```

After downtime, cron fires, mbsync fetches all accumulated mail, and the
processor handles the entire batch. No special catch-up logic needed — this
falls out naturally from Maildir semantics.

## Directory Layout

**Tool (git repo):**

```
mail-workflows/
+-- bin/
|   +-- run                # Entry point (lock → sync → process)
|   +-- sync               # Wraps mbsync
|   +-- process            # Core processor loop
|   +-- init               # One-time data dir initialization
+-- preprocessors/         # Small scripts, each does one thing
|   +-- extract-pdf-text   # PDF attachment → plain text
|   +-- strip-html         # HTML body → plain text
|   +-- extract-headers    # Emit structured header summary
+-- handlers/              # Post-processing / notification scripts
|   +-- save-artifact      # Write output to artifacts/
|   +-- notify-desktop     # macOS desktop notification
|   +-- notify-telegram    # Send Telegram message
|   +-- notify-email       # Send email notification
+-- defaults/              # Shipped defaults, copied on first init
|   +-- accounts.yml.example
|   +-- rules/
|   |   +-- bank-statements.yml
|   |   +-- bank-notifications.yml
|   +-- prompts/
|       +-- bank-statement.md
|       +-- bank-notification.md
+-- .mbsyncrc.template     # Template, rendered from accounts.yml
```

**User data (`$MAIL_WORKFLOWS_HOME`, default `~/.mail-workflows/`):**

```
~/.mail-workflows/
+-- accounts.yml           # IMAP accounts, notification settings
+-- rules/                 # One YAML per rule
|   +-- bank-statements.yml
|   +-- bank-notifications.yml
+-- prompts/               # Prompt templates referenced by rules
|   +-- bank-statement.md
|   +-- bank-notification.md
+-- mail/                  # Maildir storage (raw MIME, managed by mbsync)
|   +-- <account>/
|       +-- <folder>/
|           +-- new/       # Unprocessed emails
|           +-- cur/       # Processed emails
|           +-- tmp/       # Maildir temp (used by mbsync)
+-- normalized/            # Plain-text markdown copies (LLM-ready)
|   +-- <account>/
|       +-- <timestamp>_<subject-slug>.md
+-- attachments/           # Extracted binary attachments
|   +-- <timestamp>_<subject-slug>/
|       +-- invoice.pdf
|       +-- photo.jpg
+-- artifacts/             # Generated outputs
+-- logs/                  # Run logs
```

The `init` command creates `$MAIL_WORKFLOWS_HOME` and copies default
rules and prompts from `defaults/` if no user config exists yet.

## Component Details

### Mail Sync — mbsync (isync)

**Why mbsync:**
- Battle-tested, actively maintained, available via Homebrew and apt
- Native Maildir support — each message becomes a separate file
- Works with any IMAP server (Gmail, Fastmail, self-hosted, etc.)
- Idempotent: re-running after downtime just downloads what's new
- Supports multiple accounts

**Config:** `.mbsyncrc` is generated from `$MAIL_WORKFLOWS_HOME/accounts.yml`
by `init`. Credentials never touch the repo.

### Account Configuration

```yaml
# ~/.mail-workflows/accounts.yml
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
# ~/.mail-workflows/rules/bank-statements.yml
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
# ~/.mail-workflows/rules/order-confirmations.yml
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
# ~/.mail-workflows/prompts/bank-statement.md
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

- **`save-artifact`**: Writes to `$MAIL_WORKFLOWS_HOME/artifacts/<rule>/<date>-<subject-slug>.json`
- **`notify-desktop`**: Uses `osascript` on macOS (terminal-notifier as
  fallback), `notify-send` on Linux
- **`notify-telegram`**: Sends message via Telegram Bot API (bot token and
  chat ID from config)
- **`notify-email`**: Sends email via configured SMTP (for forwarding
  summaries to another address)

Notification config (tokens, chat IDs, SMTP settings) lives in
`accounts.yml` under a `notifications` key:

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

### Email Normalization

Each synced email gets a plain-text markdown copy, separate from the raw
Maildir. The normalized copy is the input for rule matching, preprocessing,
and LLM handlers. The raw Maildir remains untouched and syncable.

**When:** Normalization runs after sync, before processing. Moving
`new/` → `cur/` in Maildir happens after successful normalization.

**Output structure:**

Normalized messages and attachments live in separate top-level directories
under `$MAIL_WORKFLOWS_HOME`:

```
normalized/<account>/
  20260308-143022_invoice-from-acme.md
  20260308-143022_weekly-report.md

attachments/
  20260308-143022_invoice-from-acme/
    invoice.pdf
    logo.png
  20260308-143022_weekly-report/
    report.xlsx
```

Messages without attachments get no attachments directory.

**Filename format:** `YYYYMMDD-HHMMSS_<subject-slug>[_<suffix>].md`

- Timestamp is the email `Date` header, converted to local time.
- Subject slug: transliterate non-Latin characters to ASCII, downcase,
  strip punctuation, replace spaces/runs with hyphens, truncate at ~60
  characters on a word boundary. Empty subjects become `no-subject`.
- Uniqueness suffix: only appended when a collision occurs (another
  message with identical timestamp and slug). Use first 8 hex characters
  of SHA-256 of the message ID. No suffix when the name is already unique.

**Attachment filenames:** original filename preserved. On collision within
the same message (duplicate attachment names), append a counter:
`invoice.pdf`, `invoice-2.pdf`, `invoice-3.pdf`.

**Markdown format:**

```markdown
---
message_id: <abc123@mail.example.com>
from: Alice <alice@example.com>
to: Bob <bob@example.com>
subject: Invoice from Acme
date: 2026-03-08T14:30:22+00:00
folder: INBOX
attachments:
  - invoice.pdf
  - logo.png
---

Hey Bob,

Please find the invoice attached.
```

Frontmatter is minimal YAML: `message_id`, `from`, `to`, `subject`, `date`
(ISO 8601), `folder` (source IMAP folder), and `attachments` (list of
filenames, omitted when none). No encoded headers, no MIME artifacts.

**Body extraction rules:**

1. Prefer `text/plain` part if available.
2. Fall back to `text/html` → convert to Markdown (using `reverse_markdown`
   gem or equivalent).
3. Strip email signatures and quoted replies where feasible.
4. Output is always valid UTF-8 with no quoted-printable or base64 remnants.

**Attachment extraction rules:**

1. Save each MIME attachment to `attachments/<message-dir>/<filename>`.
2. Inline images (Content-Disposition: inline) are also extracted.
3. Attachments are binary files, written verbatim from `attachment.decoded`.
4. The `attachments` list in frontmatter references filenames only (no paths);
   the attachments directory name matches the markdown filename stem.

**Idempotency:** if a normalized `.md` file already exists for a given
message ID (checked via frontmatter), skip re-normalization.

**Implementation:** Ruby using the `mail` gem for MIME parsing. The
normalizer is a thin wrapper (~100-150 lines) that reads a raw `.eml` file
and writes the markdown + attachment files.

## State Management

**No database.** State transitions use Maildir's own directory conventions:

1. mbsync delivers mail to `new/`
2. Normalization creates markdown + attachments, then moves `.eml` to `cur/`
3. Processing (rule matching, handlers) operates on normalized files

If normalization fails, the `.eml` stays in `new/` and is retried next run.
After N consecutive failures on the same message, move it to `failed/`
and log a warning.

Processed emails are kept in `cur/` indefinitely.

A simple lockfile (`flock` on `$MAIL_WORKFLOWS_HOME/.lock`) prevents
concurrent runs.

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

# 2. Install dependencies + initialize data directory
bin/init                   # installs mbsync, pdftotext, ruby gems via brew/apt
                           # creates ~/.mail-workflows/ with default rules & prompts
                           # copies accounts.yml.example → ~/.mail-workflows/accounts.yml

# 3. Configure
$EDITOR ~/.mail-workflows/accounts.yml   # add IMAP credentials, notification tokens

# 4. Add bin/ to PATH (init offers to do this)
export PATH="$HOME/mail-workflows/bin:$PATH"

# 5. Schedule
# init offers to install the cron entry:
#   */5 * * * * mail-workflows-run >> ~/.mail-workflows/logs/cron.log 2>&1
```

To replicate on another machine: clone repo, run `bin/init`, edit accounts.yml.
To update: `git pull` in the repo directory. User config is untouched.
To backup: copy `~/.mail-workflows/` (or just `accounts.yml` + `rules/` +
`prompts/` if you don't need mail archives).

## Robustness

| Concern | Solution |
|---------|----------|
| Concurrent runs | `flock` on lockfile, second run skips |
| Downtime / missed crons | mbsync fetches all accumulated mail; processor handles batch |
| Processing failure | Email stays in `new/`, retried next run; moved to `failed/` after N retries |
| Partial output | Artifacts written to temp file, renamed atomically on success |
| Credential security | `accounts.yml` lives outside repo; passwords via external commands |
| Large attachments | Preprocessors extract text; raw attachments not sent to LLM |
