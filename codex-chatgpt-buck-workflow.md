# Codex <-> ChatGPT via Buck

Use this note when Richard asks Codex to communicate directly with ChatGPT instead of having him copy/paste messages.

## Purpose

Codex can send prompts to ChatGPT locally through Buck and wait for the JSON reply on stdout. ChatGPT acts as the Chief Information Technology Officer (CITO) and code reviewer. Codex is the senior developer assistant. GPT approves all plans and edits before they are applied.

## Prerequisites

1. Buck.app is always running as a menu bar app — do NOT launch it before every message.
2. ChatGPT desktop app must be open with a visible window.
3. Long-running shell commands must be allowed. Use up to 900 seconds if needed.

## Required command

```bash
"$HOME/Mac Projects/buck/buck-review.sh" \
  --prompt "your prompt here" \
  --text "content to send here" \
  --timeout 900
```

For stdin content (preferred for multi-line):

```bash
"$HOME/Mac Projects/buck/buck-review.sh" \
  --prompt "your prompt here" \
  --stdin <<'BUCKEOF'
content here
BUCKEOF
```

## Buck script path

```bash
/Users/rjamesy/Mac Projects/buck/buck-review.sh
```

## Process

1. Call `buck-review.sh` with `--prompt` and either `--text` or `--stdin`.

   If the call fails with a connection/process error, launch Buck and retry:
   ```bash
   open /Applications/Buck.app && sleep 2
   ```

2. Wait for JSON on stdout.
3. Parse the JSON internally — **do NOT show the raw JSON to Richard.**
   Extract and act on:
   - `status` — the decision: `"approved"`, `"feedback"`, or `"error"`
   - `response` — GPT's text (the actual content to read and act on)
   - optional `id`, `round`, `timestamp` — metadata, ignore unless debugging

## Expected JSON shape

```json
{
  "id": "review_...",
  "response": "...",
  "round": 1,
  "status": "approved|feedback|error",
  "timestamp": "..."
}
```

## Response Handling (CRITICAL)

**Never show raw JSON to Richard.** Parse it internally and act on the `status` field:

| `status` | What to do |
|---|---|
| `"approved"` | Proceed immediately. Apply the edit or move to next step. Briefly tell Richard "GPT approved" if relevant. |
| `"feedback"` | Read `response` for GPT's instructions. Revise your work accordingly. Resend to GPT. Do NOT show the JSON — just act on the feedback. |
| `"error"` | Something went wrong with Buck/ChatGPT. Retry once. If still error, tell Richard. |

**Do NOT do this:**
```
ChatGPT replied:
{
  "id": "review_...",
  "response": "Acknowledged.\n\n[BUCK: Ready for compact]",
  "status": "feedback",
  ...
}
```

**Do this instead:**
- If `status` is `"approved"` → say "GPT approved" and proceed
- If `status` is `"feedback"` → read the `response` text, revise your work, resend to GPT
- If GPT says "Acknowledged" with `status: "feedback"` → GPT is waiting for more input or has concerns. Read the `response` carefully — it may contain instructions after "Acknowledged"

**Key rule:** The `status` field is the decision, not the `response` text. A response containing "APPROVED" in the text but with `status: "feedback"` means GPT has feedback. Always trust `status` over text content.

## Important notes

- The Buck script does **not** accept `--prompt` by itself. It also needs `--text` or `--stdin`.
- A real working example:

```bash
"$HOME/Mac Projects/buck/buck-review.sh" \
  --prompt "Reply with a short hello to Codex." \
  --text "Hello from Codex." \
  --timeout 900
```

- Codex has already verified this works locally and received a JSON response from ChatGPT through Buck.

---

## Prompt Framing (CRITICAL)

The `--prompt` field tells ChatGPT **who is talking and what role GPT plays**. Always identify as Codex. Always assign GPT the reviewer/authority role.

### First message — plan review

```bash
--prompt "You are the Chief Information Technology Officer. Codex (OpenAI's coding agent) is your assistant — a senior software developer. Be terse — short sentences, no filler. Reply APPROVED if good. Otherwise state exactly what to change."
```

### First message — edit review

```bash
--prompt "You are reviewing code changes by Codex (OpenAI's coding agent). Be terse. Reply APPROVED if good. Otherwise state exactly what to change — no explanations, no commentary, no pleasantries."
```

### Follow-up messages (after first exchange)

```bash
--prompt ""
```

Empty prompt on follow-ups. GPT retains context from the conversation within the same Buck session.

### Ask mode (question to GPT)

```bash
--prompt "You are answering a question from Codex (an AI coding agent). Be terse — short sentences, no filler."
```

### Challenge mode (skeptical review)

```bash
--prompt "Act as a skeptical staff engineer. Try to disprove this plan. Focus on concurrency, retries, idempotency, stale context, data loss, and failure recovery. First line: APPROVED or FEEDBACK."
```

---

## Contract Between Codex and ChatGPT

This is the agreement that governs how Codex and GPT collaborate. Follow these rules exactly.

### Authority

1. **GPT is the authority.** GPT approves or rejects. Codex follows GPT's instructions.
2. **Richard is NOT involved** in the review loop. GPT is the sole approver.
3. If GPT and Codex cannot agree after **3 rounds on the same edit**, THEN ask Richard.

### Workflow: Auto Edit Review (Default)

This is the default mode. When Codex has a plan or code changes ready:

1. **Send the plan to GPT first.** Do not code anything until GPT says APPROVED.

2. **If GPT says FEEDBACK:** Revise the plan per GPT's instructions. Resend. Do NOT involve Richard. Repeat until APPROVED.

3. **Once APPROVED, execute edits one at a time.** For each edit, send to GPT BEFORE applying:

```
Edit [N]/[total] — [file_path]

BEFORE:
```
[existing code]
```

AFTER:
```
[proposed new code]
```
```

4. **Parse GPT's response for each edit:**
   - Contains "APPROVED" or `status: "approved"` → apply the edit immediately, move to next
   - Otherwise → revise the edit per GPT's feedback and resend. Do NOT ask Richard.

5. **After all edits applied**, send completion summary to GPT:

```
All [total] edits applied. Done.
```

6. Report the final result to Richard.

### Challenging GPT

Codex should challenge GPT when it disagrees. Present evidence (exact code, line numbers, file paths). GPT may be wrong. But if GPT insists after seeing the evidence, follow GPT's instruction.

### What Codex Must Never Do

- Never apply code changes without GPT approval
- Never ask Richard for permission when GPT can decide
- Never say "Want me to start?" or present options to Richard — just do the work
- Never skip the GPT review step even for "small" changes
- **Never show raw JSON responses from Buck to Richard** — parse internally and act on the `status` field
- Never treat `status: "feedback"` as approval — always read GPT's feedback and revise

---

## Modes Summary

| Mode | When to Use | Prompt Style |
|---|---|---|
| **Auto edit review** | Default for all code changes | Plan → APPROVED → edit-by-edit review |
| **Ask** | Quick question to GPT | Single question, single answer |
| **Challenge** | Want GPT to try to break a plan | Skeptical review, APPROVED or FEEDBACK |
| **Chat** | Open-ended discussion with GPT | Multi-turn, converge on approach |
| **Review** | Formal plan approval | Send plan file, get approved/feedback |

---

## Example: Full Edit Review Session

```bash
# 1. Send plan for approval
"$HOME/Mac Projects/buck/buck-review.sh" \
  --prompt "You are reviewing code changes by Codex (OpenAI's coding agent). Be terse. Reply APPROVED if good. Otherwise state exactly what to change." \
  --stdin <<'BUCKEOF'
Plan: Fix sitemap to use search index

Change src/app/api/sitemap.xml/route.ts:
- Replace businesses table query with business_search_index query
- This ensures only eligible businesses appear in sitemap

APPROVED or FEEDBACK?
BUCKEOF

# 2. If approved, send each edit
"$HOME/Mac Projects/buck/buck-review.sh" \
  --prompt "" \
  --stdin <<'BUCKEOF'
Edit 1/1 — src/app/api/sitemap.xml/route.ts

BEFORE:
  const { data: businesses } = await supabase
    .from('businesses')
    .select('slug, updated_at')
    .eq('status', 'published')

AFTER:
  const { data: businesses } = await supabase
    .from('business_search_index')
    .select('slug, indexed_at')

APPROVED or FEEDBACK?
BUCKEOF

# 3. If approved, apply edit and send completion
"$HOME/Mac Projects/buck/buck-review.sh" \
  --prompt "" \
  --text "All 1/1 edits applied. Done."
```
