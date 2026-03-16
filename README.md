# Mail Workflows

Automatically process incoming emails — extract data, match against processing routes, handle with LLM, and send notifications.

## Prerequisites

- **Ruby** (3.0+)
- **mbsync** (part of [isync](https://isync.sourceforge.io/)) — syncs IMAP mail to local Maildir
- **MarkItDown** ([microsoft/markitdown](https://github.com/microsoft/markitdown)) — converts PDF attachments to Markdown for LLM processing

Install on macOS:

```bash
brew install isync pipx
pipx install 'markitdown[pdf]'
```

Install on Linux (Debian/Ubuntu):

```bash
sudo apt install isync pipx
pipx install 'markitdown[pdf]'
```

## Quick Start

```bash
git clone git@github.com:dreikanter/mail-workflows.git ~/mail-workflows
cd ~/mail-workflows
bin/mw init
$EDITOR ~/.mail-workflows/config.yml
```

## Running

```bash
bin/mw run
```

This is the main entry point. It acquires a lock (to prevent concurrent runs), then:

1. **Sync** — generates `.mbsyncrc`, runs `mbsync` to pull new mail, normalizes messages into markdown
2. **Process** — matches normalized messages against rules, runs handlers

Normalized messages go to `~/.mail-workflows/normalized/<account>/new/`.

## Passwords

Passwords are never stored in config files. Instead, `config.yml` references external commands via `pass_cmd` that retrieve credentials at runtime.

On macOS, use Keychain:

```bash
# Store a password
security add-generic-password -s mail-workflows-personal -a "$USER" -w "your-imap-password"

# Verify it works
security find-generic-password -s mail-workflows-personal -w
```

Then reference it in `~/.mail-workflows/config.yml`:

```yaml
accounts:
  personal:
    pass_cmd: "security find-generic-password -s mail-workflows-personal -w"
```

On Linux, use `pass`, `secret-tool`, or any command that prints the password to stdout.

### Gmail

Gmail requires an App Password for IMAP access:

1. Generate an App Password at https://myaccount.google.com/apppasswords (select "Mail")
2. Store the password in Keychain (omit spaces, `aaaa bbbb cccc dddd` → `aaaabbbbccccdddd`):

```bash
security add-generic-password -s mail-workflows-personal -a "$USER" -w "your-app-password"
```

To update an existing password, delete and re-add:

```bash
security delete-generic-password -s mail-workflows-personal
security add-generic-password -s mail-workflows-personal -a "$USER" -w "new-app-password"
```

## Development

Install dependencies:

```bash
bundle install
```

Run tests:

```bash
bundle exec rake
```

See [docs/specs/](docs/specs/) for architecture and design specs.
