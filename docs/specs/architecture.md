# Mail Workflows — Architecture Spec

## Overview

An automated system that syncs email from IMAP servers to local Maildir
storage, normalizes messages to LLM-ready Markdown, and (planned) runs
configurable processing handlers on incoming emails.

## Design Principles

- **Maildir as the source of truth.** Each email is a file. No databases.
  State tracking uses Maildir's own `new/` → `cur/` convention.
- **Cron as the scheduler.** No long-running daemons. A single cron entry
  runs sync + normalize. Missed runs just mean a bigger batch next time.
- **Tool ≠ data.** The git repo is the tool. User data and configuration
  live in a separate directory (`~/.mail-workflows/` by default, override
  with `$MAIL_WORKFLOWS_HOME`). The tool is easy to update (`git pull`);
  user data never touches GitHub.

## High-Level Flow

```
cron (every N minutes)
  +-- mw run
      +-- 1. acquire lock (flock, skip if already running)
      +-- 2. generate .mbsyncrc from accounts.yml
      +-- 3. run mbsync to pull new mail → Maildir new/
      +-- 4. normalize: for each .eml in new/
              +-- parse MIME (mail gem)
              +-- write markdown + YAML frontmatter → normalized/
              +-- extract attachments → attachments/
              +-- convert PDF attachments to Markdown (MarkItDown)
              +-- move .eml to cur/ (marks as synced)
```

After downtime, cron fires, mbsync fetches all accumulated mail, and the
normalizer handles the entire batch. No special catch-up logic needed — this
falls out naturally from Maildir semantics.

## Directory Layout

**Tool (git repo):**

```
mail-workflows/
+-- bin/
|   +-- mw                # CLI entry point
+-- lib/
|   +-- cli.rb            # Command dispatcher
|   +-- normalizer.rb     # MIME → Markdown conversion
|   +-- maildir.rb        # Single maildir operations
|   +-- maildir_store.rb  # Account/folder enumeration
|   +-- mbsyncrc_generator.rb
|   +-- mailer.rb         # SMTP email sending
|   +-- slug.rb           # Subject slugification
|   +-- log.rb            # Structured logging
|   +-- version.rb
+-- test/
+-- docs/
    +-- specs/
        +-- architecture.md   # This file
        +-- handlers.md       # Handler system design (planned)
```

**User data (`$MAIL_WORKFLOWS_HOME`, default `~/.mail-workflows/`):**

```
~/.mail-workflows/
+-- accounts.yml           # IMAP accounts, notification settings
+-- rules/                 # One YAML per rule (planned)
+-- prompts/               # Prompt templates (planned)
+-- mail/                  # Maildir storage (raw MIME, managed by mbsync)
|   +-- <account>/
|       +-- <folder>/
|           +-- new/       # Unprocessed by normalizer
|           +-- cur/       # Normalized
|           +-- tmp/       # Maildir temp (used by mbsync)
+-- normalized/            # Markdown copies with YAML frontmatter
|   +-- <account>/
|       +-- new/           # Normalized, not yet processed by handlers
|       +-- <timestamp>_<subject-slug>.md
+-- attachments/           # Extracted binary attachments
|   +-- <timestamp>_<subject-slug>/
|       +-- invoice.pdf
+-- log/                   # Run logs
    +-- sync.log
    +-- cron.log
```

The `mw init` command creates this directory structure and writes a template
`accounts.yml`.

## CLI Commands

| Command | Purpose |
|---------|---------|
| `mw init [PATH]` | Initialize data directory |
| `mw run` | Sync mail and normalize |
| `mw schedule <period>` | Enable cron (e.g. `5m`, `15m`, `1h`) |
| `mw unschedule` | Disable cron |
| `mw status` | Show schedule and account summary |
| `mw purge --confirm` | Delete mail, normalized, and attachment data |
| `mw version` | Show version |

Global option `--path DIR` overrides the data directory.

## Mail Sync — mbsync (isync)

- Battle-tested, actively maintained, available via Homebrew and apt
- Native Maildir support — each message becomes a separate file
- Works with any IMAP server (Gmail, Fastmail, self-hosted, etc.)
- Idempotent: re-running after downtime just downloads what's new
- Supports multiple accounts

`.mbsyncrc` is generated from `accounts.yml` at the start of each run.

## Account Configuration

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
```

Passwords are retrieved via an external command (`pass_cmd`), not stored in
the config file. On macOS, use Keychain. On Linux, use `pass`, `secret-tool`,
or any command that prints the password to stdout.

Port defaults to 993, TLS defaults to true, folders defaults to `["INBOX"]`.

## Email Normalization

Each synced email gets a Markdown copy with YAML frontmatter. The normalized
copy is the input for future rule matching and LLM handlers. The raw Maildir
remains untouched.

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
forwarded_by: Carol <carol@example.com>
forwarded_date: 2026-03-07T10:00:00+00:00
---

Email body text here.
```

Frontmatter fields: `message_id`, `from`, `to`, `subject`, `date` (ISO 8601),
`folder`. Optional: `attachments` (list of filenames, omitted when none),
`forwarded_by` and `forwarded_date` (when forwarded message detected).

**Filename format:** `YYYYMMDD-HHMMSS_<subject-slug>[_<hash>].md`

- Timestamp from the email `Date` header, converted to local time
- Subject slug: transliterate non-Latin to ASCII (babosa gem), downcase,
  strip punctuation, truncate at ~60 characters on word boundary
- Hash suffix (first 8 hex of SHA-256 of message ID) only on collision

**Body extraction:**

1. Prefer `text/plain` part if available
2. Fall back to `text/html` → convert to Markdown (`reverse_markdown` gem)
3. Strip email signatures (`-- ` delimiter)
4. Output is always valid UTF-8

**Attachment extraction:**

- Save to `attachments/<message-stem>/<filename>`
- Inline images are also extracted
- On filename collision within a message: `invoice.pdf`, `invoice-2.pdf`
- MIME-encoded filenames are decoded
- PDF attachments are converted to Markdown using
  [MarkItDown](https://github.com/microsoft/markitdown) and saved alongside
  the original (e.g., `invoice.pdf` → `invoice.pdf.md`)

**Forwarded message detection:**

- Inline markers (`---------- Forwarded message ----------`)
- `X-Forwarded-For` header
- Extracts original sender, subject, and date into frontmatter

**Idempotency:** if a normalized `.md` already exists for a given message ID
(checked via frontmatter scan), skip re-normalization.

## State Management

State transitions use directory conventions:

1. mbsync delivers raw `.eml` to `mail/<account>/<folder>/new/`
2. Normalization writes `.md` to `normalized/<account>/new/`, then moves
   `.eml` to `mail/<account>/<folder>/cur/`

All state transitions are atomic renames on the same filesystem.

If normalization fails, the `.eml` stays in `new/` and is retried next run.

A lockfile (`flock` on `$MAIL_WORKFLOWS_HOME/.lock`) prevents concurrent
runs. A second invocation exits silently.

## Robustness

| Concern | Solution |
|---------|----------|
| Concurrent runs | `flock` on lockfile, second run skips |
| Downtime / missed crons | mbsync fetches all accumulated mail; normalizer handles batch |
| Normalization failure | `.eml` stays in `new/`, retried next run |
| Credential security | `accounts.yml` lives outside repo; passwords via external commands |

## Dependencies

| Dependency | Purpose | Install |
|-----------|---------|---------|
| Ruby 3.0+ | Core tool | System or version manager |
| mbsync (isync) | IMAP sync | `brew install isync` / `apt install isync` |
| mail gem | MIME parsing | `bundle install` |
| babosa gem | Slug transliteration | `bundle install` |
| reverse_markdown gem | HTML → Markdown | `bundle install` |
| MarkItDown | PDF → Markdown (for handlers) | `pipx install 'markitdown[pdf]'` |
