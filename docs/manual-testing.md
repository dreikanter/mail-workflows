# Manual Testing Guide: Handler System

Exercises the full `mw run` pipeline end-to-end using an isolated test directory. Covers rule matching, handler execution (script + LLM), failure handling, preprocessed content, and file lifecycle.

All commands use `mw --path /tmp/mw-test run` to avoid touching real `~/.mail-workflows/` data. The test directory uses `accounts: {}` so mbsync is skipped — only the processor runs.

## Prerequisites

- `claude` CLI installed and authenticated (for LLM handler tests)
- Ruby with bundled gems available
- The repo checked out with `bin/mw` available

## Setup

### 1. Create test directory

```bash
TEST_DIR=/tmp/mw-test
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/{rules,prompts,state,handlers,log}
mkdir -p $TEST_DIR/normalized/personal/{new,processed,failed}

cat > $TEST_DIR/accounts.yml << 'EOF'
accounts: {}
EOF
```

### 2. Create test emails

```bash
cat > $TEST_DIR/normalized/personal/new/20260301-080000_bank-statement.md << 'EOF'
---
message_id: "<stmt-001@megabank.com>"
from: "statements@megabank.com"
to: "user@example.com"
subject: "Monthly Statement - February 2026"
date: "2026-03-01T08:00:00+00:00"
folder: INBOX
---

Your February statement is ready.
Total spending: $4,230.00
Account balance: $12,500.00
EOF

cat > $TEST_DIR/normalized/personal/new/20260302-090000_newsletter.md << 'EOF'
---
message_id: "<news-001@techweekly.com>"
from: "digest@techweekly.com"
to: "user@example.com"
subject: "Tech Weekly #142"
date: "2026-03-02T09:00:00+00:00"
folder: INBOX
---

This week in tech:
- New database engine benchmarks
- Rust 2.0 preview announced
- AI code review tools compared
EOF

cat > $TEST_DIR/normalized/personal/new/20260303-100000_random-email.md << 'EOF'
---
message_id: "<misc-001@example.com>"
from: "friend@example.com"
to: "user@example.com"
subject: "Lunch tomorrow?"
date: "2026-03-03T10:00:00+00:00"
folder: INBOX
---

Are you free for lunch tomorrow at noon?
EOF
```

### 3. Create shared test handler

This script echoes its JSON input back as the output, so we can inspect what the processor sent:

```bash
cat > $TEST_DIR/handlers/echo.sh << 'SCRIPT'
#!/bin/bash
ruby -rjson -e '
  input = JSON.parse(STDIN.read)
  output = {
    "summary" => "Processed: #{input["email"]["subject"]}",
    "body" => "From: #{input["email"]["from"]}",
    "data" => { "input" => input }
  }
  puts JSON.generate(output)
'
SCRIPT
chmod +x $TEST_DIR/handlers/echo.sh
```

### 4. Define helper functions

```bash
# Run processor and show log output
run_test() {
  bin/mw --path $TEST_DIR run 2>&1
}

# Reset test emails to new/ for next scenario
reset_emails() {
  mv $TEST_DIR/normalized/personal/processed/*.md $TEST_DIR/normalized/personal/new/ 2>/dev/null
  mv $TEST_DIR/normalized/personal/failed/*.md $TEST_DIR/normalized/personal/new/ 2>/dev/null
  rm -f $TEST_DIR/rules/*.yml
  rm -rf $TEST_DIR/state/*
}
```

---

## Test Scenarios

### Scenario 1: No rules — all emails move to processed

**Setup:** Ensure `rules/` is empty.

```bash
rm -f $TEST_DIR/rules/*.yml
```

**Run:**

```bash
run_test
```

**Expect:**
- Log: `no rule matched` for each email, `0 matched, 3 processed`
- `new/` is empty, `processed/` has 3 files

**Verify:**

```bash
ls $TEST_DIR/normalized/personal/new/
ls $TEST_DIR/normalized/personal/processed/
```

**Reset:**

```bash
reset_emails
```

### Scenario 2: Script handler matches and executes

**Setup:**

```bash
cat > $TEST_DIR/rules/01-bank.yml << 'EOF'
name: bank-statements
match:
  from: megabank.com
handler:
  type: script
  command: handlers/echo.sh
notify: []
EOF
```

**Run:**

```bash
run_test
```

**Expect:**
- Log: `rule matched: bank-statements` for the bank email
- Bank email moved to `processed/`, other 2 also moved to `processed/`
- State output at `state/bank-statements/*.json`

**Verify:**

```bash
cat $TEST_DIR/state/bank-statements/*.json | ruby -rjson -e 'puts JSON.pretty_generate(JSON.parse(STDIN.read))'
```

Should show `summary: "Processed: Monthly Statement - February 2026"`, and `data.input.email` with all frontmatter fields plus body.

**Reset:**

```bash
reset_emails
```

### Scenario 3: LLM handler matches and executes

**Setup:**

```bash
cat > $TEST_DIR/prompts/summarize.md << 'PROMPT'
Summarize this email in one sentence.

Respond with valid JSON only, no markdown fences:
{"summary": "one sentence summary", "body": "", "data": {}}

Email:
{{EMAIL_CONTENT}}
PROMPT

cat > $TEST_DIR/rules/01-newsletter.yml << 'EOF'
name: newsletter-summary
match:
  from: techweekly
handler:
  type: llm
  prompt: summarize
  model: haiku
notify: []
EOF
```

**Run** (expect ~5-15 seconds for claude call):

```bash
run_test
```

**Expect:**
- Log: `llm handler: model=haiku prompt=summarize`
- State output at `state/newsletter-summary/*.json`
- JSON has a coherent `summary` about the tech newsletter

**Verify:**

```bash
cat $TEST_DIR/state/newsletter-summary/*.json | ruby -rjson -e 'puts JSON.pretty_generate(JSON.parse(STDIN.read))'
```

**Reset:**

```bash
reset_emails
```

### Scenario 4: Handler failure moves to failed

**Setup:**

```bash
cat > $TEST_DIR/handlers/fail.sh << 'SCRIPT'
#!/bin/bash
echo "something broke" >&2
exit 1
SCRIPT
chmod +x $TEST_DIR/handlers/fail.sh

cat > $TEST_DIR/rules/01-fail.yml << 'EOF'
name: fail-test
match:
  from: megabank.com
handler:
  type: script
  command: handlers/fail.sh
notify: []
EOF
```

**Run:**

```bash
run_test
```

**Expect:**
- Log: `handler failed for ...bank-statement.md`
- Bank email moved to `failed/` (not `processed/`)
- Other 2 emails moved to `processed/` (no match)

**Verify:**

```bash
ls $TEST_DIR/normalized/personal/failed/
ls $TEST_DIR/normalized/personal/processed/
```

**Reset:**

```bash
reset_emails
```

### Scenario 5: Preprocessed attachment content

**Setup:**

```bash
# Create fake preprocessed attachment for the bank email
STEM="20260301-080000_bank-statement"
mkdir -p $TEST_DIR/attachments/$STEM
echo "Extracted PDF: Total spending $4,230, balance $12,500" \
  > $TEST_DIR/attachments/$STEM/statement.pdf.md

cat > $TEST_DIR/rules/01-preproc.yml << 'EOF'
name: preproc-test
match:
  from: megabank.com
handler:
  type: script
  command: handlers/echo.sh
notify: []
EOF
```

**Run:**

```bash
run_test
```

**Expect:**
- State output contains `preprocessed` field with key `statement.pdf`
- Value is `"Extracted PDF: Total spending $4,230, balance $12,500"`

**Verify:**

```bash
cat $TEST_DIR/state/preproc-test/*.json | ruby -rjson -e '
  data = JSON.parse(STDIN.read)
  pp data["data"]["input"]["preprocessed"]
'
```

**Reset:**

```bash
reset_emails
rm -rf $TEST_DIR/attachments/$STEM
```

### Scenario 6: Regex rule matching

**Setup:**

```bash
cat > $TEST_DIR/rules/01-regex.yml << 'EOF'
name: regex-test
match:
  from: /mega.*bank/i
handler:
  type: script
  command: handlers/echo.sh
notify: []
EOF
```

**Run:**

```bash
run_test
```

**Expect:**
- Bank email matches (`megabank.com` matches `/mega.*bank/i`)
- Other 2 emails do not match

**Verify:**

```bash
ls $TEST_DIR/state/regex-test/
```

Should contain exactly one JSON file (for the bank email).

**Reset:**

```bash
reset_emails
```

### Scenario 7: First-match-wins rule priority

**Setup:**

```bash
cat > $TEST_DIR/rules/01-first.yml << 'EOF'
name: first-wins
match:
  from: megabank
handler:
  type: script
  command: handlers/echo.sh
notify: []
EOF

cat > $TEST_DIR/rules/02-second.yml << 'EOF'
name: second-loses
match:
  from: megabank
handler:
  type: script
  command: handlers/echo.sh
notify: []
EOF
```

**Run:**

```bash
run_test
```

**Expect:**
- State output saved under `state/first-wins/`, NOT `state/second-loses/`
- Log: `rule matched: first-wins`

**Verify:**

```bash
ls $TEST_DIR/state/first-wins/ 2>/dev/null && echo "first-wins: has output"
ls $TEST_DIR/state/second-loses/ 2>/dev/null && echo "second-loses: has output" || echo "second-loses: empty (correct)"
```

**Reset:**

```bash
reset_emails
```

### Scenario 8: AND logic — all match criteria must match

**Setup:**

```bash
cat > $TEST_DIR/rules/01-and.yml << 'EOF'
name: and-test
match:
  from: megabank
  subject: statement
handler:
  type: script
  command: handlers/echo.sh
notify: []
EOF
```

**Run:**

```bash
run_test
```

**Expect:**
- Bank email matches (from contains "megabank" AND subject contains "statement")
- Other emails do not match (from doesn't contain "megabank")

**Verify:**

```bash
ls $TEST_DIR/state/and-test/
```

**Reset:**

```bash
reset_emails
```

### Scenario 9: Handler config passed through

**Setup:**

```bash
cat > $TEST_DIR/rules/01-config.yml << 'EOF'
name: config-test
match:
  from: megabank
handler:
  type: script
  command: handlers/echo.sh
  custom_threshold: 1000
  currency: USD
notify: []
EOF
```

**Run:**

```bash
run_test
```

**Expect:**
- Handler input `config` field contains `{"custom_threshold" => 1000, "currency" => "USD"}`
- Handler-specific keys (`type`, `command`) are stripped from config

**Verify:**

```bash
cat $TEST_DIR/state/config-test/*.json | ruby -rjson -e '
  data = JSON.parse(STDIN.read)
  pp data["data"]["input"]["config"]
'
```

Should print `{"custom_threshold"=>1000, "currency"=>"USD"}`.

**Reset:**

```bash
reset_emails
```

---

## Cleanup

Remove the entire test directory:

```bash
rm -rf /tmp/mw-test
```

No changes were made to `~/.mail-workflows/`.
