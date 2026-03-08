# Mail Workflows

Automatically process incoming emails — extract data, match against processing routes, handle with LLM, and send notifications.

## Quick Start

```bash
git clone git@github.com:dreikanter/mail-workflows.git ~/mail-workflows
cd ~/mail-workflows
bin/init
$EDITOR ~/.mail-workflows/accounts.yml
```

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

See [SPEC.md](SPEC.md) for details.
