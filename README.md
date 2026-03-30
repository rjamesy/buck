# Buck

> Let your AI coding agents talk to each other — and to any desktop AI app.

Buck is a macOS toolkit that bridges AI coding assistants (Claude Code, Codex, Cursor, etc.) with desktop AI apps (ChatGPT, Cursor IDE) via the Accessibility API. It automates the copy-paste review loop: your coding agent writes a plan, Buck injects it into the target app, the target reviews it, and Buck pipes the feedback back — all without you touching the keyboard.

## Components

| Component | Type | Purpose |
|-----------|------|---------|
| **Buck** | Menu bar app | Core ChatGPT bridge — send/read messages via AX API |
| **CursorBridge** | Module in Buck | Cursor IDE chat injection — keyboard simulation + AX bubble reading |
| **Rogers** | Menu bar app | ChatGPT session archiver — polls AX tree, stores in SQLite, summarizes via Ollama |
| **BuckTeams** | Window app | Multi-AI group chat (User + Claude + Codex + GPT) — partial implementation |
| **BuckCodex** | Window app | OpenAI Codex UI — direct API client for local Codex sessions |
| **BuckSpeak** | Menu bar app | Voice I/O — text-to-speech and speech recognition for voice-loop testing |

## How It Works

### ChatGPT Bridge (original)

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
   - Set the text in the input field (AXValue on AXTextArea)
   - Press the Send button (AXPressAction on AXButton with AXHelp "Send message")
   - Poll for GPT's response (text stability, send button state, message group count)
5. **ResponseWriter** writes the response JSON to `~/.buck/outbox/`
6. **buck-review.sh** polls the outbox, reads the response, and outputs it

No network calls. No API keys. Just file-based IPC and the Accessibility API.

### Cursor Bridge (new)

```
Any process                  test-cursor-bridge              Cursor IDE
       |                            |                            |
       |-- runs binary ----------->|                            |
       |                            |-- AXManualAccessibility -->|  (forces webview AX tree)
       |                            |-- AXFocus composer ------->|  (no Cmd+L toggle)
       |                            |-- CGEvent keystrokes ----->|  (type + Enter)
       |                            |                            |
       |                            |<-- reads bubble-* domIds --|  (AXStaticText values)
       |                            |                            |
       |<-- prints response --------|                            |
```

Cursor is Electron/Chromium. Its webview doesn't expose content to AX by default. CursorBridge solves this:

1. **AXManualAccessibility** forces Chromium to build an AX tree from the webview DOM
2. **AX focus** on `composer-toolbar-section` focuses the chat input without toggling the panel (Cmd+L is a toggle — sending it when the panel is open closes it)
3. **CGEvent.postToPid** types the message character-by-character and presses Enter
4. **domId tracking** verifies the message was delivered (new `bubble-*` IDs, immune to scroll-induced count changes)
5. **Text stability polling** on the last bubble detects response completion

Requires `"force-renderer-accessibility": true` in `~/.cursor/argv.json` (one-time setup, Cursor restart needed).

## Features

- **Menu bar app** — no dock icon, always running silently in the background
- **Two AI targets** — ChatGPT (AXValue + button press) and Cursor (keyboard simulation + AX bubble reading)
- **File-based IPC** — JSON in/out via `~/.buck/inbox/` and `~/.buck/outbox/`
- **Smart response detection** — multiple heuristics to know when GPT is done:
  - Text stability across consecutive polls
  - Send button disappearance/reappearance (ChatGPT)
  - Message group count changes (ChatGPT)
  - Bubble domId tracking (Cursor)
  - Tool-use indicator filtering ("Looked at Terminal", etc.)
- **Automatic retry** — message send retries (3 attempts), shell script retries (configurable)
- **Send verification** — confirms message delivery via domId diffing before polling for response
- **Focus resilience** — periodic re-activation during typing to survive focus contention from other apps
- **Concurrency control** — one request at a time per channel, in-flight rejection with graceful retry
- **Atomic file writes** — write to `.tmp`, rename to `.json` (no partial reads)
- **Structured prompts** — default prompt enforces strict APPROVED/FEEDBACK first-line contract with `<plan>` tag isolation
- **Truncation handling** — clicks "Show full message", "See more", "Scroll to bottom" automatically
- **Session management** — tracks conversations in SQLite, monitors GPT latency, auto-compacts long threads
- **Incremental summarization** — local Ollama (qwen2.5:3b-instruct) summarizes every turn for context preservation
- **Auto-compact** — when GPT slows down, signals Claude to refresh the thread with an injected summary
- **Caller identification** — `--caller` flag tags requests by AI agent; menu bar shows an orange dot for Claude, blue for Codex
- **Multi-channel** — run parallel Claude Code sessions, each targeting a different ChatGPT window (main vs companion chat)
- **Detailed logging** — all activity logged to `~/.buck/logs/buck.log`

## Architecture

### Buck (Core)

```
Buck/Buck/
├── BuckApp.swift           SwiftUI menu bar entry point
├── BuckCoordinator.swift   Request orchestration, state management, approval detection
├── ChatGPTBridge.swift     ChatGPT AX bridge: send messages, read responses, poll for completion
├── CursorBridge.swift      Cursor AX bridge: keyboard simulation, bubble reading, AX focus
├── FileWatcher.swift       DispatchSource + timer fallback watching ~/.buck/inbox/
├── ResponseWriter.swift    Atomic JSON writes to ~/.buck/outbox/
├── Models.swift            ReviewRequest / ReviewResponse codables
├── SessionManager.swift    Session tracking, latency monitoring, compact orchestration
├── ChatHistoryStore.swift  SQLite persistence for sessions and messages
└── OllamaSummarizer.swift  Local LLM summarization via Ollama
```

### Other Components

```
Rogers/                     ChatGPT session archiver — polls AX, stores in SQLite, summarizes
BuckTeams/                  Multi-AI group chat (User + Claude + Codex + GPT) — partial
BuckCodex/                  OpenAI Codex UI — direct API client
BuckSpeak/                  Voice I/O — TTS and speech recognition
BuckSpeakV3/                Voice I/O for Teams context
```

### Shell Scripts

| Script | Purpose |
|--------|---------|
| `buck-review.sh` | CLI for sending reviews to ChatGPT via Buck |
| `buck-speak.sh` | CLI for voice I/O via BuckSpeak |
| `buck-teams.sh` | CLI for multi-AI group chat via BuckTeams |
| `buck-exec.sh` | CLI for autonomous code execution via Buck |
| `test-cursor-bridge.swift` | Test harness for CursorBridge (must be compiled) |

### AX Tree Paths

**ChatGPT:**
```
ChatGPT Window
└── AXGroup
    └── AXSplitGroup
        └── AXGroup (chat pane — most children)
            └── AXScrollArea
                └── AXList → AXList → AXGroup (message groups)
                    └── AXGroup → AXStaticText (AXValue or AXDescription)
```

**Cursor:**
```
Cursor Window
└── AXGroup → AXWebArea → AXGroup (AXWebApplication)
    └── AXGroup (domId="workbench.panel.aichat.*")
        └── AXGroup (domId="bubble-*")         ← chat messages
            └── AXStaticText (AXValue)
        └── AXGroup (domId="composer-toolbar-section")  ← input area
```

### Response Detection

The hardest problem Buck solves: knowing when the AI is done generating. It uses three independent signals:

**ChatGPT:**
1. **Text stability** — response text unchanged for 3–4 consecutive polls (2s interval)
2. **Send button cycle** — button disappears (generation active) then reappears for 2 consecutive polls
3. **Identical response with new groups** — handles repeated responses by checking message group count

**Cursor:**
1. **Text stability** — last bubble text unchanged for 3–4 consecutive polls
2. **domId diffing** — new bubble IDs appearing relative to pre-send baseline

## Usage

### ChatGPT Review (buck-review.sh)

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

### Cursor Chat Injection (test-cursor-bridge)

```bash
# Compile once (must be compiled — swift interpreter drops CGEvents)
swiftc "$HOME/Mac Projects/buck/test-cursor-bridge.swift" -o /tmp/test-cursor-bridge

# Count chat bubbles
/tmp/test-cursor-bridge count

# Read last response
/tmp/test-cursor-bridge read

# Send a message and wait for response
/tmp/test-cursor-bridge send "Your message here"
```

Prerequisites:
- `~/.cursor/argv.json` must contain `"force-renderer-accessibility": true` (requires Cursor restart)
- The binary (or Buck.app) must have Accessibility permission
- Cursor must be running with the chat panel open

### Script Options (buck-review.sh)

| Flag | Default | Description |
|------|---------|-------------|
| `--prompt "..."` | Structured review prompt | Custom system prompt for GPT |
| `--stdin` | — | Read content from stdin |
| `--text "..."` | — | Inline content (use --stdin for long text) |
| `--session ID` | — | Session UUID for history tracking and compact |
| `--timeout N` | 720 | Seconds to wait for response |
| `--channel X` | `$BUCK_CHANNEL` or none | Target channel (`a` = main window, `b` = companion chat) |
| `--caller NAME` | `$BUCK_CALLER` or none | Caller identifier (e.g. `claude`, `codex`) — sets menu bar icon color |
| `--retries N` | 2 | Max retries on error |

### Multi-channel

Buck supports independent channels so multiple Claude Code sessions can each talk to their own ChatGPT window:

| Channel | ChatGPT window | AX subrole |
|---------|---------------|------------|
| `a` (default) | Main window | `AXStandardWindow` |
| `b` | Companion chat | `AXSystemDialog` |

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

Shell aliases for multi-channel Claude Code:
```bash
alias claude-a='BUCK_CHANNEL=a BUCK_CALLER=claude claude --allow-dangerously-skip-permissions'
alias claude-b='BUCK_CHANNEL=b BUCK_CALLER=codex claude --allow-dangerously-skip-permissions'
```

### Caller identification

| Caller | Menu bar indicator |
|--------|-------------------|
| `claude` | Orange dot overlay |
| `codex` | Blue dot overlay |
| (none) | Default icon, no dot |

```bash
buck-review.sh --caller claude --stdin <<'BUCKEOF'
content
BUCKEOF
```

## BuckSpeak — Voice I/O

BuckSpeak is a separate local speak/listen tool for voice-loop testing. It does not use the ChatGPT review path.

```bash
# Speak only
~/Mac\ Projects/buck/buck-speak.sh --speak --text "Hey ARIA"

# Listen only
~/Mac\ Projects/buck/buck-speak.sh --listen

# Speak, then listen
~/Mac\ Projects/buck/buck-speak.sh --speak-listen --text "Hey ARIA"
```

- Auto-launches `BuckSpeak.app` if needed
- Listen mode runs inside the app process (handles macOS microphone/speech permissions)
- Default voice: `Lee Premium`
- Output: JSON with `status`, `spoken_text`, `heard_text`, timing fields

## Rogers — Session Archiver

Rogers is a menu bar app that monitors ChatGPT conversations via the AX API and archives them:

- Polls the ChatGPT AX tree to detect new sessions and messages
- Stores sessions and messages in SQLite with fingerprint-based deduplication
- Summarizes conversations locally via Ollama (qwen2.5)
- Provides a window UI for browsing archived sessions

## BuckTeams — Multi-AI Group Chat (Partial)

BuckTeams coordinates a 4-way group chat between User, Claude, Codex, and GPT:

- 3-column UI: participants, chat, decisions
- Message routing: CLI agents via file IPC, GPT via AX bridge, user via UI
- `~/.buckteams/chat.jsonl` as single source of truth (NDJSON append-only)
- Consensus detection for decisions (≥2 agents agree or user confirms)
- `buck-teams.sh` CLI interface

Status: Core coordinator, chat log, participant tracking, and decision store implemented. UI views need full integration.

## Integrating with Claude Code

Buck uses two CLAUDE.md files:

| File | Location | Purpose |
|------|----------|---------|
| **Project CLAUDE.md** | `<project-root>/CLAUDE.md` | Teaches Claude how to call `buck-review.sh` and `test-cursor-bridge` |
| **Global CLAUDE.md** | `~/.claude/CLAUDE.md` | Auto-review workflow — GPT reviews every plan and edit automatically |

The project file is included in this repo. For the global file:

```bash
# If you don't have a global CLAUDE.md yet:
cp examples/global-claude-md.md ~/.claude/CLAUDE.md

# If you already have one, append it:
cat examples/global-claude-md.md >> ~/.claude/CLAUDE.md
```

For Codex, see [AGENTS.md](AGENTS.md).

### Suggested commands in Claude Code

| Command | What happens |
|---------|-------------|
| **"send to buck"** / **"get GPT review"** | Sends the current plan to GPT for approval |
| **"chat with gpt about X"** | AI-to-AI discussion between Claude and GPT |
| **"ask gpt about X"** | Single-shot question to GPT |
| **"challenge gpt on this"** | Skeptical review — GPT tries to break the plan |
| **"say hello to cursor"** | Sends a message to Cursor's chat via CursorBridge |

These are natural language triggers from the global CLAUDE.md instructions, not slash commands.

## Runtime Directories

| Path | Purpose |
|------|---------|
| `~/.buck/inbox/` | Incoming review requests (JSON) |
| `~/.buck/outbox/` | Outgoing review responses (JSON) |
| `~/.buck/logs/buck.log` | Debug log (Buck + CursorBridge) |
| `~/.buck/history.db` | SQLite session history (7-day retention) |
| `~/.buckspeak/inbox/` | BuckSpeak IPC requests |
| `~/.buckspeak/outbox/` | BuckSpeak IPC responses |
| `~/.buckteams/chat.jsonl` | BuckTeams chat log (NDJSON) |
| `~/.buckteams/staging/` | BuckTeams agent message submissions |
| `~/.buckteams/participants/` | BuckTeams presence/status files |

## Requirements

- macOS 14.0+
- Xcode 15+ (to build)
- ChatGPT desktop app (for ChatGPT bridge)
- Cursor IDE (for Cursor bridge) with `force-renderer-accessibility: true` in `~/.cursor/argv.json`
- Accessibility permission granted to Buck (and/or compiled test binaries)
- Ollama with `qwen2.5:3b-instruct` model (optional — for session summarization)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for code style, testing, and PR guidelines. High-impact areas:

- Response detection improvements
- AX tree resilience (both ChatGPT and Cursor)
- New AI target support (Gemini, Claude desktop, local models)
- BuckTeams UI integration
- Pre-built releases

## License

MIT — see [LICENSE](LICENSE).
