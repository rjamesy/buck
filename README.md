# Buck

> Let your AI coding agents talk to each other — and to any desktop AI app.

Buck is a macOS toolkit that bridges AI coding assistants (Claude Code, Codex, Cursor, etc.) with desktop AI apps (ChatGPT, Cursor IDE) via the Accessibility API, or directly with OpenAI models via the Responses API (Codex channel). It automates the copy-paste review loop: your coding agent writes a plan, Buck injects it into the target app (or calls the API), the target reviews it, and Buck pipes the feedback back — all without you touching the keyboard.

## Components

| Component | Type | Purpose |
|-----------|------|---------|
| **Buck** | Menu bar app | Core ChatGPT bridge — send/read messages via AX API |
| **CursorBridge** | Module in Buck | Cursor IDE chat injection — keyboard simulation + AX bubble reading |
| **CodexBridge** | Module in Buck | OpenAI Responses API — direct HTTP calls, no desktop app needed |
| **buck-context** | Shell CLI (Python) | Persistent project memory + conversation log; all Buck exchanges auto-log to SQLite, structured memories survive across sessions, GPT can curate via `MEMORY[<cat>]:` markup |
| **Rogers** | Menu bar app | ChatGPT session archiver — polls AX tree, stores in SQLite, summarizes via Ollama |
| **BuckTeams** | Window app | Multi-AI group chat — GPT + Codex via OpenAI API, Claude via file IPC |
| **BuckCodex** | Window app | OpenAI Codex UI — direct API client for local Codex sessions |
| **BuckSpeak** | Menu bar app | Voice I/O — text-to-speech and speech recognition for voice-loop testing |
| **TwilioBridge** | Module in Buck | SMS notifications — push info or questions to the user's phone via Twilio; polls inbound replies |
| **buck-notify.sh** | Shell CLI | User-friendly wrapper for the TwilioBridge (info-push and ask-and-wait-for-reply) |

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
   - Poll for GPT's response (send button visible + stop button absent for 3 consecutive polls = complete)
5. **ResponseWriter** writes the response JSON to `~/.buck/outbox/`
6. **buck-review.sh** polls the outbox, reads the response, and outputs it

No network calls. No API keys. Just file-based IPC and the Accessibility API.

### Codex Bridge (direct API)

```
Claude Code / Codex                    Buck (menu bar)                   OpenAI API
       |                                    |                                  |
       |-- writes JSON to ~/.buck/inbox/ -->|                                  |
       |                                    |-- POST /v1/responses ----------->|
       |                                    |                                  |
       |                                    |<-- JSON response ----------------|
       |                                    |                                  |
       |<-- writes JSON to ~/.buck/outbox/ -|                                  |
       |                                    |                                  |
       |  (reads response, acts on it)      |                                  |
```

Unlike ChatGPT and Cursor bridges, CodexBridge makes direct HTTP calls to the OpenAI Responses API. No desktop app, no Accessibility API — just a REST call. Same file-based IPC, same `buck-review.sh` interface, same JSON response format.

Requires `~/.buck/codex-config.json`:
```json
{
  "api_key": "sk-proj-...",
  "model": "gpt-5.3-codex"
}
```

### Cursor Bridge

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
2. **Brief activation** — Cursor is activated once (Electron requires key focus for keyboard events), then the previous app is immediately restored after typing
3. **CGEvent.postToPid** types the message character-by-character and presses Enter (direct PID delivery)
4. **domId tracking** verifies the message was delivered (new `bubble-*` IDs, immune to scroll-induced count changes)
5. **Text stability polling** on the last bubble detects response completion

Note: AXValue cannot be used to inject text into Cursor's Monaco editor (it updates the AX tree but not the editor state). Keyboard simulation via `postToPid` is required.

Requires `"force-renderer-accessibility": true` in `~/.cursor/argv.json` (one-time setup, Cursor restart needed).

## Features

- **Menu bar app** — no dock icon, always running silently in the background
- **Three AI targets** — ChatGPT (AXValue + button press, fully background), Cursor (brief activate + postToPid + auto-restore), and Codex (direct OpenAI API, no app needed)
- **File-based IPC** — JSON in/out via `~/.buck/inbox/` and `~/.buck/outbox/`
- **Smart response detection** — send button is the authoritative signal for ChatGPT, plus defensive layers:
  - Send button visible + stop button absent for 3 consecutive polls (ChatGPT)
  - Never returns partial text on timeout — throws so callers see a clean error
  - Message group count changes (ChatGPT — handles identical-text replies)
  - Bubble domId tracking (Cursor)
  - Tool-use indicator filtering ("Looked at Terminal", etc.)
- **Automatic retry** — message send retries (3 attempts), shell script retries (configurable)
- **Send verification** — confirms message delivery via domId diffing before polling for response
- **Focus resilience** — Cursor briefly activates for typing then immediately restores the previous app
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
├── CodexBridge.swift       Codex API bridge: direct HTTP to OpenAI Responses API
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
| `buck-review.sh` | CLI for sending reviews to ChatGPT, Cursor, or Codex via Buck |
| `buck-speak.sh` | CLI for voice I/O via BuckSpeak |
| `buck-teams.sh` | CLI for multi-AI group chat via BuckTeams (join, send, poll, listen) |
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

The hardest problem Buck solves: knowing when the AI is done generating.

**ChatGPT — send-button sovereignty (the only completion signal):**
1. **Send button cycle** — button disappears (generation starts), stop button appears, then send button reappears AND stop button disappears for 3 consecutive polls = done
2. **Stop button positive check** — resets the send-button counter while generation is active; guards against phase-transition flicker
3. **Identical response with new groups** — handles the rare case where GPT's reply is byte-identical to the previous message; only counts when send-button sovereignty also holds
4. **Timeout throws** — on deadline, the bridge throws `BridgeError.timeout` rather than returning partial text, so callers never silently consume a truncated reply

Text stability was previously a completion signal but was removed — mid-stream GPT pauses (thinking, large context, slow networks) would trigger false completions.

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
| `--channel X` | `$BUCK_CHANNEL` or none | Target channel (`a` = main window, `b` = companion chat, `cursor`, `codex`) |
| `--caller NAME` | `$BUCK_CALLER` or none | Caller identifier (e.g. `claude`, `codex`) — sets menu bar icon color |
| `--retries N` | 2 | Max retries on error |

### Multi-channel

Buck supports independent channels so multiple Claude Code sessions can each talk to their own AI target:

| Channel | Target | Method |
|---------|--------|--------|
| `a` (default) | ChatGPT main window | AX API (`AXStandardWindow`) |
| `b` | ChatGPT companion chat | AX API (`AXSystemDialog`) |
| `cursor` | Cursor IDE chat panel | Keyboard simulation + AX |
| `codex` | OpenAI Responses API | Direct HTTP (no desktop app) |

```bash
# Via env var
BUCK_CHANNEL=b buck-review.sh --stdin <<'BUCKEOF'
content
BUCKEOF

# Via flag
buck-review.sh --channel b --stdin <<'BUCKEOF'
content
BUCKEOF

# Send to Codex (direct API)
buck-review.sh --channel codex --stdin <<'BUCKEOF'
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

## buck-notify — SMS notifications (Twilio)

`buck-notify.sh` lets Claude reach you by SMS when you're away from the terminal. Two modes:

```bash
# Fire-and-forget info push (phone shows: INFO-<msg>)
~/Mac\ Projects/buck/buck-notify.sh --info "Build passed, deploying..."

# Ask a question and wait up to 10 minutes for an SMS reply (phone shows: QUES-<msg>)
~/Mac\ Projects/buck/buck-notify.sh --ask "Proceed with migration? (yes/no)"

# Ask with a custom reply timeout
~/Mac\ Projects/buck/buck-notify.sh --ask "Short question" --timeout 60
```

Output JSON:

```json
{ "status": "sent|reply|error", "response": "..." }
```

- `status: sent` — info pushed (`response` is `"sent"`).
- `status: reply` — user replied; `response` is the reply text verbatim.
- `status: error` — timeout, rate-limited, or Twilio API error.

### How it works

1. The shell writes a JSON request to `~/.buck/inbox/` with `channel: "twilio"` and a `[BUCK-MODE:info]` or `[BUCK-MODE:ask:N]` tag.
2. Buck's `TwilioBridge` POSTs the SMS via Twilio's Messages API.
3. For `--ask`, the bridge then polls `GET /Messages.json?From=<user>` every 5 s and returns the first inbound reply newer than the send timestamp.
4. If the user doesn't reply in time, the bridge auto-forwards the question to the ChatGPT channel as a fallback and returns `"[via=chatgpt_fallback] <answer>"`.

No webhook / public endpoint is needed — replies are retrieved by polling Twilio's REST API.

### Safety limits

All enforced by `TwilioBridge`, configurable in `~/.buck/twilio-config.json`:

| Limit | Default | Config key |
|---|---|---|
| Max message length (truncated with `...`) | 480 chars | `max_message_length` |
| Max sends per rolling 60 min | 20 | `max_per_hour` |
| Minimum interval between sends | 2 s | `min_interval_sec` |

Send timestamps persist to `~/.buck/twilio-rate.json` so limits survive Buck restarts. Only successful Twilio POSTs count.

### Setup (one-time)

Create `~/.buck/twilio-config.json` (mode 600):

```json
{
  "account_sid": "AC...",
  "auth_token":  "...",
  "from_number": "+15551234567",
  "to_number":   "+61412345678"
}
```

Twilio's default auto-reply ("Thanks for the message. Configure your number's SMS URL...") can be silenced by creating a TwiML Bin in the Twilio console with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Response></Response>
```

…and setting "A MESSAGE COMES IN" on the phone number to use that bin.

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

## buck-context — Persistent Project Memory

`buck-context` is a single-file Python CLI (stdlib only — `sqlite3` + `argparse`) that gives every project under Buck a persistent, queryable memory of categorised facts plus a full Claude↔GPT↔Codex conversation log. Backing store is one SQLite file at `~/.buck/memory.db`, keyed on the project's absolute path.

### Why

Without it, Claude Code sessions forget everything between terminal launches. CLAUDE.md captures the broad project rules, but ephemeral state (current refactor stage, server hostnames, do/don'ts learned this hour, what GPT just decided) gets lost when you `exit` the shell. buck-context closes that loop:

- Categorised memories survive forever (or until explicitly deleted/archived)
- Every `buck-review.sh` exchange auto-logs to a `messages` table — full transcript
- Cross-session retrieval (`--all-sessions`) lets you ask "did I ever write down X?" from any project
- GPT can curate memories itself by emitting `MEMORY[<category>]: <one-line content>` in any reply — `buck-review.sh` parses + persists
- Pushing context into a fresh ChatGPT thread is one command (`push-gpt`) with a chunked READY/ACK/LOADED handoff
- Old chat can be lossily summarised via local Ollama (`compact`) — categorised memories never touched
- Snapshot/restore via STRATA-compressed archive blobs

### Schema (SQLite, `~/.buck/memory.db`)

```
projects        path PK, title, last_active_at, summary
memories        id, project FK, category, key, content, importance, expires_at
memories_audit  every create/update/delete tracked
messages        id, project FK, request_id, agent, direction (out|in), channel, status, content
archives        id, project FK, title, raw_bytes, compressed_bytes, compression, blob, metadata_json
```

`PRAGMA user_version = 2` (v1 = core tables, v2 = archives).

### Categories

`must_do` · `must_read` · `do_dont` · `server_config` · `current_state` · `decision` · `failed_approach` · `plan` · `open_question` · `glossary` · `code_location` · `tool_pref` · `workflow` · `permission` · `persona` · `external_ref` · `fact` · `chat_summary`

Strings, additive — anything else works too. `recap` orders by a curated list.

### Common usage

```bash
# Bootstrap a project (idempotent)
cd ~/your-project
buck-context init

# Read everything
buck-context recap                                    # markdown brief
buck-context list --cat=server_config                 # tabular
buck-context search "ai-server" --all-sessions        # cross-project

# Write
buck-context write must_do "ship buck-context tests"
buck-context write server_config "AI box: rjamesy@100.103.104.48" --key=ai-server --importance=8
buck-context write decision "chose hash-id over AX-id" --importance=7
buck-context update <id> "<new content>"
buck-context delete <id> --reason="completed"

# Cross-session
buck-context sessions list                            # registered projects
buck-context sessions show buck                       # recap by path-prefix
buck-context recap --session=~/AI_Projects/AI_Server  # different project
```

### Hand-off to a fresh ChatGPT thread

```bash
buck-context push-gpt --channel=a              # default 20k chars/chunk
buck-context push-gpt --max-chunk=10000        # smaller chunks
buck-context push-gpt --resume-from=4          # retry from chunk 4 after a partial fail
buck-context push-gpt --dry-run                # show chunk plan only
```

Protocol: preamble → `READY` → 1..N-1 chunks → `ACK` each → final chunk → `LOADED`. Each step has 2 retries. The whole handoff is logged into `messages` like any other exchange.

### Archive / restore

```bash
buck-context archive --title="post-launch"     # snapshot memories + last 200 messages
buck-context archives list
buck-context archives view <id>                # markdown render
buck-context archives restore <id>             # additive restore (audit-tracked)
buck-context archives export <id> > snap.json  # portable BUCKCTX1 envelope
buck-context archives import < snap.json
buck-context archives delete <id>
```

Compression: prefers `~/AI_Projects/STRATA/strata.py` if importable, falls back to zlib level 9. ~90% smaller than raw JSON for typical transcripts (zlib + 1 byte for STRATA's mode tag — STRATA's structural transforms don't help on plain text but don't hurt either).

### Selective Ollama compaction

```bash
buck-context compact --dry-run                                    # preview, no writes
buck-context compact --chat-older=14d --keep-last=200             # live
buck-context compact --model=qwen2.5:7b-instruct --all-sessions   # every project
```

Older messages → chunked → Ollama summary written as `memories.category='chat_summary'` → originals deleted with audit. **Categorised memories (`must_do`, `do_dont`, `server_config`, `decision`, etc.) are never touched by `compact`.** Aborts cleanly with no deletions if Ollama is unreachable.

### Session-start menu (Claude Code bootstrap)

```bash
buck-context menu --json
```

Returns a hierarchical `screens` object (`main` → `manage` → `find`/`edit`/`archives`). Each screen has ≤4 options to fit Claude's `AskUserQuestion` cap. Walk it via chained pickers; descend on `next_screen`, run on `command`, prompt for `<placeholder>` slots inline. The project + global `CLAUDE.md` blocks instruct Claude to call this as the very first action in any buck-context-enabled project.

### Integration with `buck-review.sh`

Built in — no separate wiring step. Every Buck exchange:
1. Auto-resolves `SESSION_ID = $(pwd -P)` if `--session` not provided
2. Logs the outbound request as a `messages` row right after the inbox file is written
3. Logs the inbound response inside the existing `log_exchange()` (alongside `history.jsonl`, which is preserved)
4. Scans the response for `^MEMORY\[<cat>\]: <content>$` lines and persists each via `buck-context write --key=gpt-suggested --importance=6`

Existing `--session SESSION_ID` flag still wins. Existing `~/.buck/history.jsonl` raw log unchanged.

### Operations

```bash
buck-context status              # project counts
buck-context log --n=20          # recent messages (this project)
buck-context prune               # delete expired memories
buck-context doctor              # schema check, orphan check
buck-context export --format=md  # backup
buck-context message-add ...     # internal — used by buck-review.sh
```

Files: `buck-context` (the CLI, ~1500 LOC Python). Database: `~/.buck/memory.db`. Existing forensic log `~/.buck/history.jsonl` is preserved untouched.

## Rogers — Session Archiver

Rogers is a menu bar app that monitors ChatGPT conversations via the AX API and archives them:

- Polls the ChatGPT AX tree to detect new sessions and messages
- Stores sessions and messages in SQLite with fingerprint-based deduplication
- Summarizes conversations locally via Ollama (qwen2.5)
- Provides a window UI for browsing archived sessions

## BuckTeams — Multi-AI Group Chat

BuckTeams coordinates a 4-way group chat between User, Claude, Codex, and GPT:

- 3-column UI: participants sidebar, chat, decisions panel
- **GPT** (`gpt-5.4-mini`) and **Codex** (`gpt-5.3-codex`) use direct OpenAI API bridges (stateful via `previous_response_id`) — no ChatGPT desktop app needed
- **Claude** participates via `buck-teams.sh` CLI (file IPC) with event-driven `--listen` mode (fswatch)
- Bridge responses don't trigger other bridges (no GPT↔Codex ping-pong loops)
- Each bridge gets its own identity prompt ("You are GPT" / "You are Codex")
- `~/.buckteams/chat.jsonl` as single source of truth (NDJSON append-only)
- Consensus detection for decisions (≥2 agents agree or user confirms)
- Claude Code hook (`UserPromptSubmit`) auto-polls for new messages on every user interaction

### Claude Code Integration

```bash
# Join a session
buck-teams.sh --join --agent claude

# Send a message
buck-teams.sh --send "message" --agent claude

# Poll for new messages (non-blocking)
buck-teams.sh --poll --agent claude

# Event-driven listener (for terminal, not Claude Code)
buck-teams.sh --listen --agent claude
```

Config: `~/.buckteams/codex-config.json` (API key shared by both GPT and Codex bridges).

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
| `~/.buck/codex-config.json` | Codex bridge config (API key + model) |
| `~/.buck/laws.txt` | LAWS reminder text auto-appended to every outbox response (missing = no-op) |
| `~/.buckspeak/inbox/` | BuckSpeak IPC requests |
| `~/.buckspeak/outbox/` | BuckSpeak IPC responses |
| `~/.buckteams/chat.jsonl` | BuckTeams chat log (NDJSON) |
| `~/.buckteams/staging/` | BuckTeams agent message submissions |
| `~/.buckteams/participants/` | BuckTeams presence/status files |
| `~/.buckteams/codex-config.json` | BuckTeams API key for GPT + Codex bridges |
| `~/.buckteams/inbox/` | BuckTeams ping files for agent wake signals |

## LAWS Reminder Injection

Buck auto-appends the contents of `~/.buck/laws.txt` to every outbox response. This keeps AI-authored rules in the requesting agent's working context at every tool-return boundary, defeating long-session drift without depending on the agent remembering to check its system prompt.

```
<GPT's response>

━━━ LAWS REMINDER (not from the other AI) ━━━
<laws.txt contents>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Setup:
```bash
cat > ~/.buck/laws.txt <<'LAWS'
Rule 1 — ...
Rule 2 — ...
Rule 3 — ...
LAWS
```

- File missing or empty → no footer, no error (backward-compatible)
- `BUCK_LAWS_OFF=1` on the Buck.app process → hard-disables injection
- Log sink: `~/.buck/logs/buck.log` records `[laws] injected` / `[laws] skipped` per response

## Requirements

- macOS 14.0+
- Xcode 15+ (to build)
- ChatGPT desktop app (for ChatGPT bridge)
- Cursor IDE (for Cursor bridge) with `force-renderer-accessibility: true` in `~/.cursor/argv.json`
- OpenAI API key (for Codex bridge) — set in `~/.buck/codex-config.json`
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
