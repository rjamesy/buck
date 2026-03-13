# Buck

> Let your AI coding agents talk to each other. Claude writes the code, GPT reviews it — automatically.

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
- **Session management** — tracks conversations in SQLite, monitors GPT latency, auto-compacts long threads
- **Incremental summarization** — local Ollama (qwen2.5:3b-instruct) summarizes every turn for context preservation
- **Auto-compact** — when GPT slows down, signals Claude to refresh the thread with an injected summary
- **Multi-channel** — run parallel Claude Code sessions, each targeting a different ChatGPT window (main vs companion chat)
- **Detailed logging** — all activity logged to `~/.buck/logs/buck.log`

## Architecture

```
Buck/Buck/
├── BuckApp.swift           SwiftUI menu bar entry point
├── BuckCoordinator.swift   Request orchestration, state management, approval detection
├── ChatGPTBridge.swift     Accessibility API: send messages, read responses, poll for completion
├── FileWatcher.swift       DispatchSource + timer fallback watching ~/.buck/inbox/
├── ResponseWriter.swift    Atomic JSON writes to ~/.buck/outbox/
├── Models.swift            ReviewRequest / ReviewResponse codables
├── SessionManager.swift    Session tracking, latency monitoring, compact orchestration
├── ChatHistoryStore.swift  SQLite persistence for sessions and messages
└── OllamaSummarizer.swift  Local LLM summarization via Ollama
```

| Component | Role |
|-----------|------|
| **BuckApp** | SwiftUI `@main`. Renders menu bar icon, status text, and control buttons. |
| **BuckCoordinator** | Receives inbox files, enforces single-request concurrency, drives the send→wait→write cycle, determines APPROVED vs FEEDBACK. |
| **ChatGPTBridge** | Core engine. Navigates the ChatGPT AX tree (Window → Group → SplitGroup → ChatPane → ScrollArea → List → MessageGroups). Sends messages by setting AXTextArea value and pressing the AXButton with AXHelp "Send message". Polls for response completion using text stability, send button state, and group count heuristics. |
| **FileWatcher** | Dual-mode file detection: DispatchSource for instant notification, 2-second timer fallback for reliability. Only processes `.json` files; cleans stale `.tmp` on startup. |
| **ResponseWriter** | Writes response JSON atomically (`.tmp` → `.json` rename). |
| **Models** | `ReviewRequest` (id, timestamp, type, promptPrefix, content, maxRounds, sessionId) and `ReviewResponse` (id, timestamp, status, response, round). Snake-case JSON coding keys. |
| **SessionManager** | Caches incoming requests, records completed request-response pairs in SQLite, triggers async Ollama summarization, checks latency trends, signals when compact is needed. |
| **ChatHistoryStore** | SQLite (macOS C library, no SPM) with three tables: `claude_sessions` (per-terminal), `gpt_sessions` (per-ChatGPT-thread), `messages`. 7-day retention with auto-cleanup. |
| **OllamaSummarizer** | HTTP POST to local Ollama (`localhost:11434`). Uses `qwen2.5:3b-instruct` for incremental conversation summarization. Fire-and-forget — never blocks the review loop. |

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

### Multi-channel

Buck supports independent channels so multiple Claude Code sessions can each talk to their own ChatGPT window simultaneously:

| Channel | ChatGPT window | AX subrole |
|---------|---------------|------------|
| `a` (default) | Main window | `AXStandardWindow` |
| `b` | Companion chat | `AXSystemDialog` |

Set the channel via the `BUCK_CHANNEL` environment variable or the `--channel` flag:

```bash
# Via env var
BUCK_CHANNEL=b buck-review.sh --stdin <<'BUCKEOF'
content
BUCKEOF

# Via flag
buck-review.sh --channel b --stdin <<'BUCKEOF'
content
BUCKEOF
```

#### Shell aliases for multi-channel Claude Code

Add these to `~/.zshrc` to launch Claude Code sessions pre-configured for a specific channel:

```bash
alias claude-a='BUCK_CHANNEL=a claude --allow-dangerously-skip-permissions'
alias claude-b='BUCK_CHANNEL=b claude --allow-dangerously-skip-permissions'
```

Then run `claude-a` in one terminal and `claude-b` in another — each session's reviews go to a different ChatGPT window.

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

To make Claude Code use Buck as an **automatic reviewer for all projects** — where GPT reviews every plan and every edit before it's applied — copy the example file into your Claude Code config:

```bash
# If you don't have a global CLAUDE.md yet:
cp examples/global-claude-md.md ~/.claude/CLAUDE.md

# If you already have one, append it:
cat examples/global-claude-md.md >> ~/.claude/CLAUDE.md
```

The full content is in [`examples/global-claude-md.md`](examples/global-claude-md.md). It configures three modes:

- **Chat mode** — AI-to-AI discussion between Claude and GPT ("chat with gpt about X")
- **Review mode** — send a plan to GPT for approval ("send to buck")
- **Auto edit review** (default) — GPT automatically reviews every plan and every code edit before Claude applies it. No user confirmation needed.

> **Path note:** The example file uses `$HOME/Mac Projects/buck/buck-review.sh`. If you cloned Buck to a different location, update the path in both your global `~/.claude/CLAUDE.md` and any project-level `CLAUDE.md` files.

#### 3. For OpenAI Codex / other agents

See [AGENTS.md](AGENTS.md) for the equivalent instructions targeting Codex. Same path note applies.

### Suggested commands in Claude Code

Once configured, these natural-language commands trigger Buck workflows:

| Command | What happens |
|---------|-------------|
| **"send to buck"** / **"get GPT review"** | Sends the current plan to GPT for approval. Returns APPROVED or FEEDBACK. |
| **"chat with gpt about X"** / **"discuss X with gpt"** | Opens an AI-to-AI discussion. Claude and GPT go back and forth, then summarise the agreed approach. |
| **"ask gpt about X"** | Single-shot question to GPT. Claude sends the question, reads the answer, reports back. |
| **"challenge gpt on this"** | Claude sends GPT a skeptical review prompt — "try to break this plan" — then reports GPT's critique. |
| **"plan with gpt"** | Claude and GPT collaborate on a plan. They iterate until converging, then present the result. |
| **"gpt is supervisor"** | Default auto-review mode. GPT reviews every plan and every edit before Claude applies it. No user confirmation. |

These aren't slash commands — they're natural language triggers that Claude Code recognises from the global CLAUDE.md instructions.

### Script options

| Flag | Default | Description |
|------|---------|-------------|
| `--prompt "..."` | Structured review prompt | Custom system prompt for GPT |
| `--stdin` | — | Read content from stdin |
| `--text "..."` | — | Inline content (use --stdin for long text) |
| `--session ID` | — | Session UUID for history tracking and compact |
| `--timeout N` | 720 | Seconds to wait for response |
| `--channel X` | `$BUCK_CHANNEL` or none | Target channel (`a` = main window, `b` = companion chat) |
| `--retries N` | 2 | Max retries on error |

## Runtime directories

| Path | Purpose |
|------|---------|
| `~/.buck/inbox/` | Incoming review requests (JSON) |
| `~/.buck/outbox/` | Outgoing review responses (JSON) |
| `~/.buck/logs/buck.log` | Debug log |
| `~/.buck/history.db` | SQLite session history (auto-created, 7-day retention) |

## Requirements

- macOS 14.0+
- Xcode 15+ (to build)
- ChatGPT desktop app (installed and open with a visible window)
- Accessibility permission granted to Buck
- Ollama with `qwen2.5:3b-instruct` model (optional — for session summarization)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). PRs welcome — especially for response detection improvements, AX tree resilience, and new AI target support.

## License

MIT — see [LICENSE](LICENSE).
