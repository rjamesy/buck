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

### From Claude Code / Codex

See [CLAUDE.md](CLAUDE.md) or [AGENTS.md](AGENTS.md) for integration instructions. The typical pattern:

```bash
# timeout: 900000
"$HOME/Mac Projects/buck/buck-review.sh" --stdin <<'BUCKEOF'
plan content
BUCKEOF
```

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
