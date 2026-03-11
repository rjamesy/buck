# Buck

A macOS menu bar app that bridges AI coding assistants (Claude Code, Codex, etc.) with the ChatGPT desktop app. Buck automates the copy-paste review loop: your coding agent writes a plan, Buck sends it to ChatGPT via the Accessibility API, ChatGPT reviews it, and Buck pipes the feedback back — all without you touching the keyboard.

## How It Works

```
Claude Code / Codex                    Buck (menu bar)                   ChatGPT Desktop
       |                                    |                                  |
       |-- writes JSON to ~/.buck/inbox/ -->|                                  |
       |                                    |-- sets text via AX API --------->|
       |                                    |-- presses Send button ---------->|
       |                                    |                                  |
       |                                    |<-- polls AX tree for response ---|
       |                                    |                                  |
       |<-- writes JSON to ~/.buck/outbox/ -|                                  |
       |                                    |                                  |
       |  (reads response, acts on it)      |                                  |
```

1. **buck-review.sh** writes a JSON request to `~/.buck/inbox/`
2. **FileWatcher** detects the new file and hands it to BuckCoordinator
3. **BuckCoordinator** parses the request and passes the prompt to ChatGPTBridge
4. **ChatGPTBridge** uses macOS Accessibility API to:
   - Find the ChatGPT window
   - Set the text in the input field
   - Press the Send button
   - Poll for GPT's response (text stability, send button state, message group count)
5. **ResponseWriter** writes the response JSON to `~/.buck/outbox/`
6. **buck-review.sh** polls the outbox, reads the response, and outputs it

No network calls. No API keys. Just file-based IPC and the Accessibility API.

## Features

- **Menu bar app** — no dock icon, runs silently in the background
- **File-based IPC** — JSON in/out via `~/.buck/inbox/` and `~/.buck/outbox/`
- **Smart response detection** — multiple heuristics to know when GPT is done:
  - Text stability across consecutive polls
  - Send button disappearance/reappearance
  - Message group count changes
  - Tool-use indicator filtering ("Looked at Terminal", etc.)
- **Automatic retry** — message send retries (3 attempts), shell script retries (configurable)
- **Concurrency control** — one request at a time, in-flight rejection with graceful retry
- **Atomic file writes** — write to `.tmp`, rename to `.json` (no partial reads)
- **Structured prompts** — default prompt enforces strict APPROVED/FEEDBACK first-line contract with `<plan>` tag isolation
- **Truncation handling** — clicks "Show full message", "See more", "Scroll to bottom" automatically
- **Detailed logging** — all activity logged to `~/.buck/logs/buck.log`

## Architecture

```
Buck/Buck/
├── BuckApp.swift           SwiftUI menu bar entry point
├── BuckCoordinator.swift   Request orchestration, state management, approval detection
├── ChatGPTBridge.swift     Accessibility API: send messages, read responses, poll for completion
├── FileWatcher.swift       DispatchSource + timer fallback watching ~/.buck/inbox/
├── ResponseWriter.swift    Atomic JSON writes to ~/.buck/outbox/
└── Models.swift            ReviewRequest / ReviewResponse codables
```

| Component | Role |
|-----------|------|
| **BuckApp** | SwiftUI `@main`. Renders menu bar icon, status text, and control buttons. |
| **BuckCoordinator** | Receives inbox files, enforces single-request concurrency, drives the send→wait→write cycle, determines APPROVED vs FEEDBACK. |
| **ChatGPTBridge** | Core engine. Navigates the ChatGPT AX tree (Window → Group → SplitGroup → ChatPane → ScrollArea → List → MessageGroups). Sends messages by setting AXTextArea value and pressing the AXButton with AXHelp "Send message". Polls for response completion using text stability, send button state, and group count heuristics. |
| **FileWatcher** | Dual-mode file detection: DispatchSource for instant notification, 2-second timer fallback for reliability. Only processes `.json` files; cleans stale `.tmp` on startup. |
| **ResponseWriter** | Writes response JSON atomically (`.tmp` → `.json` rename). |
| **Models** | `ReviewRequest` (id, timestamp, type, promptPrefix, content, maxRounds) and `ReviewResponse` (id, timestamp, status, response, round). Snake-case JSON coding keys. |

### AX Tree Path

```
ChatGPT Window
└── AXGroup
    └── AXSplitGroup
        └── AXGroup (chat pane — most children)
            └── AXScrollArea
                └── AXList
                    └── AXList
                        └── AXGroup (message groups)
                            └── AXGroup
                                └── AXStaticText (AXValue or AXDescription)
```

### Response Detection

The hardest problem Buck solves: knowing when GPT is done generating. It uses three independent signals:

1. **Text stability** — response text unchanged for 3–4 consecutive polls (2s interval)
2. **Send button cycle** — button disappears (generation active) then reappears for 2 consecutive polls
3. **Identical response with new groups** — handles repeated responses (e.g. "APPROVED" twice) by checking message group count increased

## Usage

### From the command line

```bash
# Review a file
~/Mac\ Projects/buck/buck-review.sh plan.md

# Review inline text via stdin (preferred)
~/Mac\ Projects/buck/buck-review.sh --stdin <<'BUCKEOF'
Your plan content here
BUCKEOF

# Custom prompt
~/Mac\ Projects/buck/buck-review.sh --prompt "Check for security issues" plan.md

# With options
~/Mac\ Projects/buck/buck-review.sh --retries 3 --timeout 600 plan.md
```

Output is JSON:
```json
{
  "id": "review_abc123_0",
  "timestamp": "2026-03-11T07:00:00Z",
  "status": "approved",
  "response": "APPROVED\n\nThe plan looks solid...",
  "round": 1
}
```

Status is one of: `approved`, `feedback`, `error`.

### Integrating with Claude Code

Buck uses two separate CLAUDE.md files with different purposes:

| File | Location | Purpose |
|------|----------|---------|
| **Project CLAUDE.md** | `<project-root>/CLAUDE.md` | Teaches Claude Code how to call `buck-review.sh` — syntax, JSON format, retry rules. Loaded when working in that project. |
| **Global CLAUDE.md** | `~/.claude/CLAUDE.md` | Tells Claude Code to **automatically** use Buck as a reviewer for every plan and every edit — the full auto-review workflow. Loaded in all projects. |

The project file is already included in this repo. The global file you need to create yourself.

#### 1. Project-level `CLAUDE.md` (already included)

The [CLAUDE.md](CLAUDE.md) in this repo tells Claude Code how to call `buck-review.sh`, interpret JSON responses, and handle retries. It's loaded automatically when Claude Code works in this project directory.

For **other projects** that should use Buck for reviews, copy `CLAUDE.md` into that project's root, or symlink it.

#### 2. Global `~/.claude/CLAUDE.md` (you must add this)

To make Claude Code use Buck as an **automatic reviewer for all projects** — where GPT reviews every plan and every edit before it's applied — add the following to your `~/.claude/CLAUDE.md`:

<details>
<summary>Click to expand full global CLAUDE.md content</summary>

```markdown
## Buck — ChatGPT Bridge

Buck is a macOS menu bar app that sends messages to ChatGPT desktop and returns responses automatically. Two modes:

### Chat mode — AI-to-AI discussion

When the user says "chat with chatgpt about X" or "discuss X with gpt":

1. Send the opening message with AI-to-AI framing:
` ` `bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "You are talking to Claude (an AI). Be terse — short sentences, no filler, no pleasantries. State conclusions, not reasoning." --stdin <<'BUCKEOF'
[what the user asked about, with any relevant context]
BUCKEOF
` ` `

2. Read GPT's response from the JSON output
3. Formulate a reply based on GPT's points — agree, push back, or refine
4. Send the follow-up (no prompt prefix needed for subsequent messages):
` ` `bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "" --stdin <<'BUCKEOF'
Your reply here...
BUCKEOF
` ` `

5. Repeat until converging on an approach
6. Summarise the agreed approach to the user
7. User may then say "send to buck" to get formal plan approval

### Review mode — plan approval

When the user says "send to buck" / "send this plan to buck" / "get GPT review":

` ` `bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" /path/to/plan.md
# or inline:
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --stdin <<'BUCKEOF'
plan content
BUCKEOF
` ` `

If status is "feedback", revise the plan and resend. If "approved", execute.

### Auto edit review — GPT supervises all edits (DEFAULT)

**CRITICAL: This is ALWAYS the default. NEVER ask the user to choose an option, confirm, or approve anything. NEVER say "Want me to start implementing?" or "Want me to go ahead?" or "Shall I make this change?" or present options. The user is NOT involved. GPT is the reviewer, not the user.**

**When Claude has a plan ready — whether from a chat discussion, a task request, or any other source — immediately proceed to send it to GPT and then implement ALL changes across ALL phases with GPT reviewing every edit. Do not stop between phases. Continue until every file is created/modified and the entire plan is fully implemented.**

When Claude has a plan, proposed changes, or an agreed approach ready to execute:

1. **Immediately send the plan to GPT** — do not ask the user first:
` ` `bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "You are reviewing code changes by Claude (an AI). Be terse. Reply APPROVED if good. Otherwise state exactly what to change — no explanations, no commentary, no pleasantries." --stdin <<'BUCKEOF'
[full plan content]
BUCKEOF
` ` `

2. **If GPT gives feedback** → revise the plan and resend. Do NOT involve the user. Repeat until GPT responds with APPROVED.

3. **Once GPT approves** → begin executing edits immediately. For each edit, send it to GPT BEFORE applying it:
` ` `bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "" --stdin <<'BUCKEOF'
Edit [N]/[total] — [file_path]

BEFORE:
` ` `
[existing code]
` ` `

AFTER:
` ` `
[proposed new code]
` ` `
BUCKEOF
` ` `

4. **Parse GPT's response for each edit**:
   - Contains "APPROVED" → apply the edit immediately, move to next
   - Otherwise → revise the edit per GPT's feedback and resend. Do NOT ask the user.
   - Only if GPT and Claude cannot agree after 3 rounds on the same edit → then ask the user

5. **After all edits applied**, send summary to GPT:
` ` `bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "" --stdin <<'BUCKEOF'
All [total] edits applied. Done.
BUCKEOF
` ` `

6. Report the final result to the user.

**NEVER ask the user for permission, confirmation, or option selection. GPT is the approver. The user only gets involved if there is an unresolvable disagreement (3+ feedback loops on one edit).**

### Common

` ` `bash
# Ensure Buck is running
pgrep -x Buck > /dev/null || open /Applications/Buck.app
` ` `

**Bash tool timeout:** Always use `timeout: 900000` (15 min) on Bash tool calls to `buck-review.sh`. Buck's internal timeouts (2×300s wait windows, 720s script timeout) exceed the default Bash tool timeout (~2 min), which would kill the script before GPT responds.

Output is JSON: `{"status": "approved|feedback|error", "response": "GPT's text"}`.

Requires: ChatGPT desktop app open with a visible window.
```

</details>

> **Note:** The triple backticks above are shown with spaces (`` ` ` ` ``) to avoid breaking the markdown. Remove the spaces when pasting into your actual `~/.claude/CLAUDE.md`.

#### 3. For OpenAI Codex / other agents

See [AGENTS.md](AGENTS.md) for the equivalent instructions targeting Codex.

### Script options

| Flag | Default | Description |
|------|---------|-------------|
| `--prompt "..."` | Structured review prompt | Custom system prompt for GPT |
| `--stdin` | — | Read content from stdin |
| `--text "..."` | — | Inline content (use --stdin for long text) |
| `--timeout N` | 720 | Seconds to wait for response |
| `--retries N` | 2 | Max retries on error |

## Runtime directories

| Path | Purpose |
|------|---------|
| `~/.buck/inbox/` | Incoming review requests (JSON) |
| `~/.buck/outbox/` | Outgoing review responses (JSON) |
| `~/.buck/logs/buck.log` | Debug log |

## Requirements

- macOS 14.0+
- Xcode 15+ (to build)
- ChatGPT desktop app (installed and open with a visible window)
- Accessibility permission granted to Buck

## License

Private project.
