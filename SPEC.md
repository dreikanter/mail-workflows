# Mail Workflows - Architecture Spec (Draft)

## Overview

An automated system that syncs Gmail to local Maildir storage, then runs
configurable processing pipelines (including AI agents) on incoming emails,
producing artifacts and notifications.

## Design Principles

- **Maildir as the source of truth.** Each email is a file. No databases.
  State tracking uses Maildir's own `new/` -> `cur/` convention.
- **Cron as the scheduler.** No long-running daemons. A single cron entry
  runs sync + process. Missed runs just mean a bigger batch next time.
- **Repo = config.** The git repo contains all scripts, rules, and prompt
  templates. Clone it, add credentials, add one cron line, done.
- **Unix philosophy.** Small composable scripts. Shell for orchestration,
  a real language for email parsing and AI calls.

## High-Level Flow

```
cron (every N minutes)
  +-- run
      +-- 1. acquire lock (flock, skip if already running)
      +-- 2. sync: mbsync pulls new mail -> Maildir new/
      +-- 3. process: for each .eml in new/
              +-- match against rules (from, subject, labels)
              +-- preprocess (extract PDF text, strip HTML, etc.)
              +-- run AI agent with matched prompt template
              +-- deliver artifacts / send notifications
              +-- move .eml to cur/ (marks as processed)
```

After downtime, cron fires, mbsync fetches all accumulated mail, and the
processor handles the entire batch. No special catch-up logic needed -- this
falls out naturally from Maildir semantics.

## Directory Layout

```
mail-workflows/
+-- bin/
|   +-- run                # Entry point (lock -> sync -> process)
|   +-- sync               # Wraps mbsync
|   +-- process            # Core processor loop
+-- config/
|   +-- accounts.yml       # IMAP credentials / account settings
|   +-- rules/             # One YAML per rule
|       +-- bank-statements.yml
|       +-- bank-notifications.yml
+-- prompts/
|   +-- bank-statement.md
|   +-- bank-notification.md
+-- preprocessors/         # Small scripts, each does one thing
|   +-- extract-pdf-text   # PDF attachment -> plain text
|   +-- strip-html         # HTML body -> plain text
|   +-- extract-headers    # Emit structured header summary
+-- handlers/              # Post-processing / notification scripts
|   +-- save-artifact      # Write output to artifacts/
|   +-- notify-desktop     # macOS/Linux desktop notification
|   +-- notify-slack       # Post to Slack webhook
+-- data/                  # gitignored
|   +-- mail/              # Maildir storage
|   |   +-- <account>/
|   |       +-- new/       # Unprocessed emails
|   |       +-- cur/       # Processed emails
|   |       +-- tmp/       # Maildir temp (used by mbsync)
|   +-- artifacts/         # AI-generated outputs
|   +-- logs/              # Run logs
+-- .mbsyncrc.template     # Template, rendered with account config
+-- setup                  # One-time setup script
```

## Component Details

### Mail Sync -- mbsync (isync)

**Why mbsync:**
- Battle-tested, actively maintained, available via Homebrew and apt
- Native Maildir support -- each message becomes a separate file
- Supports Gmail labels via IMAP folder mapping
- Idempotent: re-running after downtime just downloads what's new
- Supports OAuth2 via external token command (future), or App Passwords
  (simple start)

**Gmail auth:** Start with App Passwords (available when 2FA is enabled).
This avoids the OAuth2 dance for initial setup. Can add OAuth2 later as an
optional upgrade path.

**Config:** `.mbsyncrc` is generated from `config/accounts.yml` by the setup
script. This keeps credentials out of the repo while making the config
reproducible.

### Processing Rules -- YAML

```yaml
# config/rules/bank-statements.yml
name: bank-statements
match:
  from: "statements@megabank.com"
  subject: "Your Monthly Statement"
  has_attachment: "*.pdf"
preprocess:
  - extract-pdf-text
prompt: bank-statement
handlers:
  - save-artifact
  - notify-desktop
```

Rules are evaluated in order of filename. First match wins (or we could
support multiple matches -- TBD).

### Preprocessors

Small standalone scripts. Each reads from stdin or a temp directory of
extracted parts, writes to stdout. They are chained in the order specified
by the rule.

Examples:
- **`extract-pdf-text`**: Uses `pdftotext` (poppler-utils) to convert PDF
  attachments to plain text. Dramatically reduces tokens vs. feeding raw PDF.
- **`strip-html`**: Converts HTML email body to plain text. Can use
  `lynx -dump`, `w3m -dump`, or a simple script.
- **`extract-headers`**: Emits a structured summary (From, To, Date, Subject)
  for the prompt context.

### AI Agent

Two modes, configurable per rule:

1. **Claude Code CLI** (non-interactive): `claude -p "prompt content"` --
   good for tasks that benefit from tool use (file writing, web fetches, etc.)
2. **Direct API call**: Simpler, cheaper for pure text-in/text-out tasks.
   A small wrapper script calls the Anthropic API with the prompt template +
   preprocessed email content.

The prompt template is a Markdown file with placeholders:

```markdown
# prompts/bank-statement.md
You are analyzing a bank statement. Extract the following:
- Statement period
- Opening balance, closing balance
- Total deposits, total withdrawals
- Number of transactions
- Any unusual transactions (>$1000 or flagged)

Output as JSON.

---
{{EMAIL_CONTENT}}
```

### Handlers (Post-processing)

Each handler is a script that receives the AI output on stdin plus metadata
via environment variables (`$RULE_NAME`, `$EMAIL_FROM`, `$EMAIL_SUBJECT`,
`$EMAIL_DATE`, etc.).

- **`save-artifact`**: Writes to `data/artifacts/<rule>/<date>-<subject-slug>.json`
- **`notify-desktop`**: Uses `osascript` on macOS, `notify-send` on Linux
- **`notify-slack`**: Posts to a Slack webhook URL (from config)

## State Management

**No database.** Maildir's `new/` -> `cur/` move is atomic (rename on the
same filesystem) and is the only state transition. If processing fails mid-way:
- The .eml stays in `new/`
- Next run retries it
- After N consecutive failures on the same message, move it to a `failed/`
  directory and log a warning

A simple lockfile (`flock` on `data/.lock`) prevents concurrent runs.

## Implementation Language

| Layer | Language | Rationale |
|-------|----------|-----------|
| Orchestration (`bin/run`, `bin/sync`) | Shell (bash) | Zero deps, portable, simple glue |
| Email parsing + rule matching (`bin/process`) | Ruby | `mail` gem is excellent for .eml/MIME. Pre-installed on macOS. Clean scripting. |
| Preprocessors | Shell / Ruby | Depends on task complexity |
| AI wrapper | Shell or Ruby | Thin wrapper around CLI or API call |
| Handlers | Shell | Simple I/O piping |

**Alternative:** Python instead of Ruby. The `email` module is in stdlib
(no gem install needed). Both are fine -- this is a matter of preference.

**Why not Go/Rust:** This is a scripting/glue system, not a high-performance
service. The overhead of compilation and static typing isn't justified.
Shell + Ruby/Python is the right weight class.

## Setup & Deployment

```bash
# 1. Clone
git clone <repo> ~/mail-workflows
cd ~/mail-workflows

# 2. Install dependencies
./setup                    # installs mbsync, pdftotext, etc. via brew/apt

# 3. Configure
cp config/accounts.yml.example config/accounts.yml
$EDITOR config/accounts.yml   # add Gmail app password

# 4. Schedule
# setup script offers to install the cron entry:
#   */5 * * * * /path/to/mail-workflows/bin/run >> /path/to/data/logs/cron.log 2>&1
```

To replicate on another machine: clone repo, run setup, edit accounts.yml.
That's it.

## Robustness

| Concern | Solution |
|---------|----------|
| Concurrent runs | `flock` on lockfile, second run skips |
| Downtime / missed crons | mbsync fetches all accumulated mail; processor handles batch |
| Processing failure | Email stays in `new/`, retried next run; moved to `failed/` after N retries |
| Partial output | Artifacts written to temp file, renamed atomically on success |
| Credential security | `accounts.yml` is gitignored; template checked in |
| Large attachments | Preprocessors extract text; raw attachments not sent to AI |

## Open Questions

1. **Language choice: Ruby vs Python?** Both work well. Ruby's `mail` gem
   has a slightly nicer API. Python's `email` is stdlib. Leaning Ruby unless
   there is a preference.

2. **Claude Code CLI vs. direct API?** CLI gives tool use but is heavier.
   Direct API is simpler for pure text processing. Could support both,
   selectable per rule.

3. **Gmail auth: App Passwords vs. OAuth2?** App Passwords are simpler but
   require 2FA. OAuth2 is more "proper" but needs token refresh
   infrastructure. Suggest starting with App Passwords.

4. **Notification channels?** Desktop notifications + file artifacts seem
   like the minimum. Slack/email/other -- which are needed?

5. **Rule matching granularity?** Just from/subject patterns, or also Gmail
   labels, body content, attachment filenames?

6. **Multiple accounts?** The architecture supports it (Maildir per account,
   mbsync channels), but is it needed from day one?

7. **Email retention policy?** Keep all processed emails in `cur/` forever,
   or prune after N days?
