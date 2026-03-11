# Buck — Claude ↔ ChatGPT Review Bridge

## What is Buck?
Buck is a macOS menu bar app that sends plans to ChatGPT for review and returns the feedback. It removes the manual copy-paste loop.

## How to use Buck for plan review

When the user asks you to get GPT's review on a plan, or when in a plan review workflow:

1. Write the plan to a temp file
2. Run the review script and wait for the response
3. Read GPT's feedback and act on it

```bash
# Send a plan file
"$HOME/Mac Projects/buck/buck-review.sh" plan.md

# Send inline text (use --stdin with heredoc to avoid shell quoting issues)
"$HOME/Mac Projects/buck/buck-review.sh" --stdin <<'BUCKEOF'
plan content here
BUCKEOF

# Custom prompt
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "Review for security issues" plan.md
```

The script blocks until GPT responds and outputs JSON:
```json
{
  "status": "approved|feedback|error",
  "response": "GPT's full response text"
}
```

## Review loop pattern

```bash
# 1. Write plan
cat > /tmp/plan.md << 'EOF'
... your plan ...
EOF

# 2. Send for review
"$HOME/Mac Projects/buck/buck-review.sh" /tmp/plan.md

# 3. If feedback, revise plan and repeat step 2
# 4. If approved, execute the plan
```

## Critical rules

- **NEVER continue if Buck fails.** If buck-review.sh returns exit code 1 or status "error" after all retries, STOP and tell the user. Do not proceed with implementation without GPT approval.
- **Complete ALL tasks if GPT approves.** Once GPT responds with APPROVED, execute every part of the plan — all phases, all files, all edits. Do not stop partway or ask for confirmation.
- **If GPT gives feedback**, revise the plan and resend to Buck. Do not involve the user unless GPT and Claude cannot agree after 3 rounds on the same point.

## Reliability notes

- The script handles retries internally (default 2 retries on error/tool-use). No need to retry from Claude Code.
- Use `timeout: 900000` (15 min) on the Bash tool call — covers Buck's 2×5min wait windows + script 720s timeout + headroom.
- Run in **foreground**, not background — Buck responses are needed before proceeding.
- `--retries N` flag overrides the default retry count (e.g. `--retries 3` for 3 retries).
- GPT may use its screen-reading tool ("Looked at Terminal") — this is expected. Buck will wait for GPT's actual text response after the tool use.

```bash
# Example with timeout on Bash tool call:
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --stdin <<'BUCKEOF'
your content
BUCKEOF
```

## Requirements
- Buck.app must be running (menu bar icon visible)
- ChatGPT desktop app must be open with a visible window
- If Buck isn't running: `open /Applications/Buck.app`
