# Mail Workflows

Automatically process incoming emails — extract data, match against processing routes, handle with LLM, and send notifications.

## Prerequisites

- **Ruby** (3.0+)
- **mbsync** (part of [isync](https://isync.sourceforge.io/)) — syncs IMAP mail to local Maildir

Install on macOS:

```bash
brew install isync
```

Install on Linux (Debian/Ubuntu):

```bash
sudo apt install isync
```

## Quick Start

```bash
git clone git@github.com:dreikanter/mail-workflows.git ~/mail-workflows
cd ~/mail-workflows
bin/init
$EDITOR ~/.mail-workflows/accounts.yml
```

## Syncing Mail

```bash
bin/sync
```

This generates `~/.mail-workflows/.mbsyncrc` from your `accounts.yml` and runs `mbsync` to pull new messages into `~/.mail-workflows/mail/<account>/<folder>/new/`.

## Passwords

Passwords are never stored in config files. Instead, `accounts.yml` references external commands via `pass_cmd` that retrieve credentials at runtime.

On macOS, use Keychain:

```bash
# Store a password
security add-generic-password -s mail-workflows-personal -a "$USER" -w "your-imap-password"

# Verify it works
security find-generic-password -s mail-workflows-personal -w
```

Then reference it in `~/.mail-workflows/accounts.yml`:

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
bundle exec ruby -Itest -e 'Dir["test/*_test.rb"].each { |f| require_relative f }'
```

See [SPEC.md](SPEC.md) for details.
