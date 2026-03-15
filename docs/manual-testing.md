# Manual Testing Guide: Handler System

Exercises the processor pipeline end-to-end against a real `~/.mail-workflows/` data directory. Covers rule matching, handler execution (script + LLM), retry/failure, preprocessed content, notifications, and file lifecycle.

## Prerequisites

- Working `~/.mail-workflows/` with `accounts.yml` configured
- At least one normalized email in `normalized/<account>/new/` (run `mw run` first, or copy a `.md` file from `processed/` back to `new/`)
- `claude` CLI installed and authenticated (for LLM handler tests)
- Ruby with bundled gems available (`bundle exec`)

## Setup

All test artifacts are created in `~/.mail-workflows/` and cleaned up at the end. The guide uses a dedicated test prefix (`_test-`) for rules and state to avoid collisions.

### 1. Ensure test emails exist

If `new/` is empty, copy a few processed emails back:

```bash
cp ~/.mail-workflows/normalized/personal/processed/20260303-*.md \
   ~/.mail-workflows/normalized/personal/new/
cp ~/.mail-workflows/normalized/personal/processed/20260306-*.md \
   ~/.mail-workflows/normalized/personal/new/
```

Pick emails you can identify by `from` or `subject` for rule matching. Note the `from` field in each:

```bash
head -5 ~/.mail-workflows/normalized/personal/new/*.md
```

### 2. Create test directories

```bash
mkdir -p ~/.mail-workflows/{rules,prompts,state,handlers}
```

### 3. Back up existing rules (if any)

```bash
if ls ~/.mail-workflows/rules/*.yml 1>/dev/null 2>&1; then
  mkdir -p /tmp/mw-test-backup
  cp ~/.mail-workflows/rules/*.yml /tmp/mw-test-backup/
fi
```

### 4. Clean rules directory for testing

```bash
rm -f ~/.mail-workflows/rules/*.yml
```

---

## Test Scenarios

Run each scenario by invoking the processor directly:

```bash
ruby -I lib -e '
  require "mail_workflows"
  home = File.expand_path("~/.mail-workflows")
  logger = MailWorkflows.create_logger(home: home)
  processor = MailWorkflows::Processor.new(home, logger: logger)
  counts = processor.run
  puts "\nResults: #{counts.inspect}"
'
```

After each scenario, check the expected outcome and reset as described.

### Scenario 1: No rules — all emails move to processed

**Setup:** Ensure `rules/` is empty (no `.yml` files).

**Run processor.**

**Expect:**
- All emails moved from `new/` to `processed/`
- Log shows `no rule matched` for each email
- `counts[:processed]` equals total email count, `counts[:matched]` is 0

**Reset:**
```bash
# Move emails back to new/ for next test
mv ~/.mail-workflows/normalized/personal/processed/20260303-*.md \
   ~/.mail-workflows/normalized/personal/new/
mv ~/.mail-workflows/normalized/personal/processed/20260306-*.md \
   ~/.mail-workflows/normalized/personal/new/
```

### Scenario 2: Script handler matches and executes

**Setup:** Create a script handler and matching rule. Adapt the `from` pattern to match one of your test emails.

```bash
cat > ~/.mail-workflows/handlers/_test-echo.sh << 'SCRIPT'
#!/bin/bash
ruby -rjson -e '
  input = JSON.parse(STDIN.read)
  output = {
    "summary" => "Processed: #{input["email"]["subject"]}",
    "body" => "From: #{input["email"]["from"]}",
    "data" => { "fields" => input["email"].keys }
  }
  puts JSON.generate(output)
'
SCRIPT
chmod +x ~/.mail-workflows/handlers/_test-echo.sh

cat > ~/.mail-workflows/rules/01-test-script.yml << 'EOF'
name: _test-script
match:
  from: orion    # <-- adjust to match one of your test emails
handler:
  type: script
  command: handlers/_test-echo.sh
notify: []
EOF
```

**Run processor.**

**Expect:**
- Matching email handled, moved to `processed/`
- Non-matching emails also moved to `processed/` (no match)
- State output saved to `state/_test-script/*.json`
- JSON output contains `summary`, `body`, `data` fields

**Verify:**
```bash
cat ~/.mail-workflows/state/_test-script/*.json
```

**Reset:**
```bash
mv ~/.mail-workflows/normalized/personal/processed/20260303-*.md \
   ~/.mail-workflows/normalized/personal/new/
mv ~/.mail-workflows/normalized/personal/processed/20260306-*.md \
   ~/.mail-workflows/normalized/personal/new/
rm -f ~/.mail-workflows/rules/01-test-script.yml
rm -rf ~/.mail-workflows/state/_test-script
```

### Scenario 3: LLM handler matches and executes

**Setup:** Create a prompt template and LLM rule.

```bash
cat > ~/.mail-workflows/prompts/_test-summarize.md << 'PROMPT'
Summarize this email in one sentence.

Respond with valid JSON only, no markdown fences:
{"summary": "one sentence", "body": "", "data": {}}

Email:
{{EMAIL_CONTENT}}
PROMPT

cat > ~/.mail-workflows/rules/01-test-llm.yml << 'EOF'
name: _test-llm
match:
  from: orion    # <-- adjust to match one of your test emails
handler:
  type: llm
  prompt: _test-summarize
  model: haiku
notify: []
EOF
```

**Run processor.** (This will call `claude -p`, expect ~5-15 seconds.)

**Expect:**
- `llm handler: model=haiku prompt=_test-summarize` in log
- State output at `state/_test-llm/*.json`
- JSON has a coherent `summary` field

**Verify:**
```bash
cat ~/.mail-workflows/state/_test-llm/*.json
```

**Reset:**
```bash
mv ~/.mail-workflows/normalized/personal/processed/20260303-*.md \
   ~/.mail-workflows/normalized/personal/new/
mv ~/.mail-workflows/normalized/personal/processed/20260306-*.md \
   ~/.mail-workflows/normalized/personal/new/
rm -f ~/.mail-workflows/rules/01-test-llm.yml
rm -f ~/.mail-workflows/prompts/_test-summarize.md
rm -rf ~/.mail-workflows/state/_test-llm
```

### Scenario 4: Handler failure and retry tracking

**Setup:** Create a rule with a failing script.

```bash
cat > ~/.mail-workflows/handlers/_test-fail.sh << 'SCRIPT'
#!/bin/bash
echo "something broke" >&2
exit 1
SCRIPT
chmod +x ~/.mail-workflows/handlers/_test-fail.sh

cat > ~/.mail-workflows/rules/01-test-fail.yml << 'EOF'
name: _test-fail
match:
  from: orion    # <-- adjust to match one of your test emails
handler:
  type: script
  command: handlers/_test-fail.sh
notify: []
EOF
```

**Run processor.**

**Expect:**
- Log shows `handler failed` and `processor error`
- Email stays in `new/` (not moved)
- `.retries` file created next to the email: `<email>.md.retries` containing `1`
- `counts[:errors]` is 1

**Verify:**
```bash
cat ~/.mail-workflows/normalized/personal/new/20260303-*.md.retries
```

**Run processor again** (two more times, or manually set retries to 3).

**Expect after 3 retries:**
```bash
# Shortcut: set retries to max
echo "3" > ~/.mail-workflows/normalized/personal/new/20260303-*.md.retries
```

Run processor one more time.

**Expect:**
- Email moved to `failed/` directory
- `.retries` file cleaned up
- `counts[:failed]` is 1
- Log shows `max retries reached, moving to failed`

**Verify:**
```bash
ls ~/.mail-workflows/normalized/personal/failed/
```

**Reset:**
```bash
mv ~/.mail-workflows/normalized/personal/failed/20260303-*.md \
   ~/.mail-workflows/normalized/personal/new/
# Move non-matching emails back too
mv ~/.mail-workflows/normalized/personal/processed/20260306-*.md \
   ~/.mail-workflows/normalized/personal/new/
rm -f ~/.mail-workflows/normalized/personal/new/*.retries
rm -f ~/.mail-workflows/rules/01-test-fail.yml
rm -rf ~/.mail-workflows/state/_test-fail
```

### Scenario 5: Preprocessed attachment content

**Setup:** Create a fake preprocessed attachment file and a handler that echoes it back.

```bash
# Pick one of your test emails and create a matching attachment dir
STEM="20260303-123100_orion-telekom-racun"
mkdir -p ~/.mail-workflows/attachments/${STEM}
echo "Extracted invoice: Total 2,500 RSD due 2026-04-01" \
  > ~/.mail-workflows/attachments/${STEM}/invoice.pdf.md

cat > ~/.mail-workflows/rules/01-test-preproc.yml << 'EOF'
name: _test-preproc
match:
  from: orion    # <-- must match the email whose STEM you used above
handler:
  type: script
  command: handlers/_test-echo.sh   # reuse the echo script from scenario 2
notify: []
EOF
```

(Recreate `_test-echo.sh` from Scenario 2 if cleaned up.)

**Run processor.**

**Expect:**
- State output contains `preprocessed` field with `invoice.pdf` key
- The value is `"Extracted invoice: Total 2,500 RSD due 2026-04-01"`

**Verify:**
```bash
ruby -rjson -e '
  f = Dir.glob(File.expand_path("~/.mail-workflows/state/_test-preproc/*.json")).first
  data = JSON.parse(File.read(f))
  pp data["data"]["input"]["preprocessed"] rescue pp data
'
```

Note: the echo script must pass through `input["preprocessed"]` in its output `data` for this to work. If using the echo script from Scenario 2, modify it to include preprocessed:

```bash
cat > ~/.mail-workflows/handlers/_test-echo.sh << 'SCRIPT'
#!/bin/bash
ruby -rjson -e '
  input = JSON.parse(STDIN.read)
  output = {
    "summary" => "Processed: #{input["email"]["subject"]}",
    "body" => "",
    "data" => { "input" => input }
  }
  puts JSON.generate(output)
'
SCRIPT
chmod +x ~/.mail-workflows/handlers/_test-echo.sh
```

**Reset:**
```bash
mv ~/.mail-workflows/normalized/personal/processed/20260303-*.md \
   ~/.mail-workflows/normalized/personal/new/
mv ~/.mail-workflows/normalized/personal/processed/20260306-*.md \
   ~/.mail-workflows/normalized/personal/new/
rm -f ~/.mail-workflows/rules/01-test-preproc.yml
rm -rf ~/.mail-workflows/state/_test-preproc
rm -rf ~/.mail-workflows/attachments/20260303-123100_orion-telekom-racun
```

### Scenario 6: Regex rule matching

**Setup:** Create a rule with regex pattern.

```bash
cat > ~/.mail-workflows/rules/01-test-regex.yml << 'EOF'
name: _test-regex
match:
  from: /orion.*telekom/i
handler:
  type: script
  command: handlers/_test-echo.sh
notify: []
EOF
```

**Run processor.**

**Expect:**
- Email from "Orion telekom" matches the case-insensitive regex
- Other emails do not match

**Reset:**
```bash
mv ~/.mail-workflows/normalized/personal/processed/20260303-*.md \
   ~/.mail-workflows/normalized/personal/new/
mv ~/.mail-workflows/normalized/personal/processed/20260306-*.md \
   ~/.mail-workflows/normalized/personal/new/
rm -f ~/.mail-workflows/rules/01-test-regex.yml
rm -rf ~/.mail-workflows/state/_test-regex
```

### Scenario 7: First-match-wins rule priority

**Setup:** Create two rules that both match the same email. The first (by filename sort) should win.

```bash
cat > ~/.mail-workflows/rules/01-test-first.yml << 'EOF'
name: _test-first-wins
match:
  from: orion
handler:
  type: script
  command: handlers/_test-echo.sh
notify: []
EOF

cat > ~/.mail-workflows/rules/02-test-second.yml << 'EOF'
name: _test-second-loses
match:
  from: orion
handler:
  type: script
  command: handlers/_test-echo.sh
notify: []
EOF
```

**Run processor.**

**Expect:**
- State output saved under `state/_test-first-wins/`, NOT `state/_test-second-loses/`
- Log shows `rule matched: _test-first-wins`

**Verify:**
```bash
ls ~/.mail-workflows/state/_test-first-wins/ && ls ~/.mail-workflows/state/_test-second-loses/ 2>&1
```

**Reset:**
```bash
mv ~/.mail-workflows/normalized/personal/processed/20260303-*.md \
   ~/.mail-workflows/normalized/personal/new/
mv ~/.mail-workflows/normalized/personal/processed/20260306-*.md \
   ~/.mail-workflows/normalized/personal/new/
rm -f ~/.mail-workflows/rules/01-test-first.yml ~/.mail-workflows/rules/02-test-second.yml
rm -rf ~/.mail-workflows/state/_test-first-wins ~/.mail-workflows/state/_test-second-loses
```

---

## Cleanup

Remove all test artifacts and restore original state:

```bash
# Remove test handlers, prompts, rules, state
rm -f ~/.mail-workflows/handlers/_test-*.sh
rm -f ~/.mail-workflows/prompts/_test-*.md
rm -f ~/.mail-workflows/rules/*test*.yml
rm -rf ~/.mail-workflows/state/_test-*
rm -f ~/.mail-workflows/normalized/personal/new/*.retries

# Remove failed/ dir if created
rm -rf ~/.mail-workflows/normalized/personal/failed/

# Ensure test emails are back in new/ (or processed/ — wherever they were originally)
# If you moved emails from processed/ to new/ for testing, move them back:
mv ~/.mail-workflows/normalized/personal/new/20260303-*.md \
   ~/.mail-workflows/normalized/personal/processed/ 2>/dev/null
mv ~/.mail-workflows/normalized/personal/new/20260306-*.md \
   ~/.mail-workflows/normalized/personal/processed/ 2>/dev/null

# Restore original rules if backed up
if [ -d /tmp/mw-test-backup ]; then
  cp /tmp/mw-test-backup/*.yml ~/.mail-workflows/rules/ 2>/dev/null
  rm -rf /tmp/mw-test-backup
fi

# Verify clean state
echo "=== rules ===" && ls ~/.mail-workflows/rules/ 2>/dev/null
echo "=== state ===" && ls ~/.mail-workflows/state/ 2>/dev/null
echo "=== new/ ===" && ls ~/.mail-workflows/normalized/personal/new/ 2>/dev/null
echo "=== processed/ count ===" && ls ~/.mail-workflows/normalized/personal/processed/ 2>/dev/null | wc -l
```
