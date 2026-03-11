# Global Instructions

## Buck — ChatGPT Bridge

Buck is a macOS menu bar app that sends messages to ChatGPT desktop and returns responses automatically.

### Ask mode — single question to GPT

When the user says "ask gpt about X" or "what does gpt think about X":

1. Send the question:
```bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "You are answering a question from Claude (an AI). Be terse — short sentences, no filler." --stdin <<'BUCKEOF'
[the user's question with any relevant context]
BUCKEOF
```
2. Read GPT's response and report it to the user.

### Challenge mode — skeptical review

When the user says "challenge gpt on this" or "have gpt try to break this":

1. Send the plan/approach with a skeptical prompt:
```bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "Act as a skeptical staff engineer. Try to disprove this plan. Focus on concurrency, retries, idempotency, stale context, data loss, and failure recovery. First line: APPROVED or FEEDBACK." --stdin <<'BUCKEOF'
[the plan or approach to challenge]
BUCKEOF
```
2. Report GPT's critique to the user. If GPT found issues, discuss them.

### Chat mode — AI-to-AI discussion

When the user says "chat with gpt about X", "discuss X with gpt", or "plan with gpt":

1. Send the opening message with AI-to-AI framing:
```bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "You are talking to Claude (an AI). Be terse — short sentences, no filler, no pleasantries. State conclusions, not reasoning." --stdin <<'BUCKEOF'
[what the user asked about, with any relevant context]
BUCKEOF
```

2. Read GPT's response from the JSON output
3. Formulate a reply based on GPT's points — agree, push back, or refine
4. Send the follow-up (no prompt prefix needed for subsequent messages):
```bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "" --stdin <<'BUCKEOF'
Your reply here...
BUCKEOF
```

5. Repeat until converging on an approach
6. Summarise the agreed approach to the user
7. User may then say "send to buck" to get formal plan approval

### Review mode — plan approval

When the user says "send to buck" / "send this plan to buck" / "get GPT review":

```bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" /path/to/plan.md
# or inline:
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --stdin <<'BUCKEOF'
plan content
BUCKEOF
```

If status is "feedback", revise the plan and resend. If "approved", execute.

### Auto edit review — GPT supervises all edits (DEFAULT)

**CRITICAL: This is ALWAYS the default. NEVER ask the user to choose an option, confirm, or approve anything. NEVER say "Want me to start implementing?" or "Want me to go ahead?" or "Shall I make this change?" or present options. The user is NOT involved. GPT is the reviewer, not the user.**

**When Claude has a plan ready — whether from a chat discussion, a task request, or any other source — immediately proceed to send it to GPT and then implement ALL changes across ALL phases with GPT reviewing every edit. Do not stop between phases. Continue until every file is created/modified and the entire plan is fully implemented.**

When Claude has a plan, proposed changes, or an agreed approach ready to execute:

1. **Immediately send the plan to GPT** — do not ask the user first:
```bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "You are reviewing code changes by Claude (an AI). Be terse. Reply APPROVED if good. Otherwise state exactly what to change — no explanations, no commentary, no pleasantries." --stdin <<'BUCKEOF'
[full plan content]
BUCKEOF
```

2. **If GPT gives feedback** → revise the plan and resend. Do NOT involve the user. Repeat until GPT responds with APPROVED.

3. **Once GPT approves** → begin executing edits immediately. For each edit, send it to GPT BEFORE applying it:
```bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "" --stdin <<'BUCKEOF'
Edit [N]/[total] — [file_path]

BEFORE:
```
[existing code]
```

AFTER:
```
[proposed new code]
```
BUCKEOF
```

4. **Parse GPT's response for each edit**:
   - Contains "APPROVED" → apply the edit immediately, move to next
   - Otherwise → revise the edit per GPT's feedback and resend. Do NOT ask the user.
   - Only if GPT and Claude cannot agree after 3 rounds on the same edit → then ask the user

5. **After all edits applied**, send summary to GPT:
```bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "" --stdin <<'BUCKEOF'
All [total] edits applied. Done.
BUCKEOF
```

6. Report the final result to the user.

**NEVER ask the user for permission, confirmation, or option selection. GPT is the approver. The user only gets involved if there is an unresolvable disagreement (3+ feedback loops on one edit).**

### Common

```bash
# Ensure Buck is running
pgrep -x Buck > /dev/null || open /Applications/Buck.app
```

**Bash tool timeout:** Always use `timeout: 900000` (15 min) on Bash tool calls to `buck-review.sh`. Buck's internal timeouts (2×300s wait windows, 720s script timeout) exceed the default Bash tool timeout (~2 min), which would kill the script before GPT responds.

Output is JSON: `{"status": "approved|feedback|error", "response": "GPT's text"}`.

Requires: ChatGPT desktop app open with a visible window.
