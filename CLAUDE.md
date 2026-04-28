# Buck — Claude ↔ AI Review Bridge

## Buck Context (session-start bootstrap)
This project uses **buck-context** for cross-session persistent memory + conversation log. Backing store: `~/.buck/memory.db` (SQLite), keyed on the project's absolute path.

**At session start, before answering anything**, run:
```bash
~/Mac\ Projects/buck/buck-context menu --json
```
Parse the JSON and present the `options[]` to the user via `AskUserQuestion` (multi-select). Each option has `key`, `label`, `desc`, `command`, `available`. Skip pending items (`available: false`) unless explicitly asked. After the user picks, run the corresponding `command` and incorporate the output into the conversation context. If they pick `skip`, proceed normally.

**During the session**, write structured state as it accrues:
```bash
buck-context write current_state "we're mid-refactor of X; tests passing on Y"
buck-context write must_do "wire up Z before commit"
buck-context write do_dont "never delete .build/ during a long inference run"
buck-context write server_config "AI server: rjamesy@100.103.104.48" --key=ai-server
buck-context write decision "chose render-stable hash over AX identifier" --importance=8
buck-context update <id> "..."          # refine an existing memory
buck-context delete <id> --reason=...   # remove redundant
```

Categories (additive, not strict): `must_do`, `must_read`, `do_dont`, `server_config`, `current_state`, `decision`, `failed_approach`, `plan`, `open_question`, `glossary`, `code_location`, `tool_pref`, `workflow`, `permission`, `persona`, `external_ref`, `fact`. Use `--global` for cross-project memories.

**Cross-session retrieval** (Claude can pull context from other projects):
```bash
buck-context recap                              # current project
buck-context recap --session=<path>             # different project
buck-context list --all-sessions --cat=server_config
buck-context search "ai-server" --all-sessions
buck-context sessions list                      # what projects exist
```

**Conversation log** is automatic: `buck-review.sh` writes every Claude→GPT→Claude exchange into `messages` keyed on the same project path. Recent tail surfaces in `recap` and via `buck-context log --n=20`.

GPT can also curate memories — emit `MEMORY[<category>]: <one-line content>` in any reply and buck-review.sh persists it via `buck-context write --key=gpt-suggested`.

## What is Buck?
Buck is a macOS menu bar app that sends messages to AI apps (ChatGPT, Cursor) via the Accessibility API, or directly to the OpenAI Responses API (Codex channel), and returns responses. It removes the manual copy-paste loop.

## How to use Buck for plan review

When the user asks you to get GPT's review on a plan, or when in a plan review workflow:

1. Write the plan to a temp file
2. Run the review script and wait for the response
3. Read GPT's feedback and act on it

```bash
# Send a plan file (defaults to ChatGPT, channel "a")
"$HOME/Mac Projects/buck/buck-review.sh" plan.md

# Send inline text (use --stdin with heredoc to avoid shell quoting issues)
"$HOME/Mac Projects/buck/buck-review.sh" --stdin <<'BUCKEOF'
plan content here
BUCKEOF

# Custom prompt
"$HOME/Mac Projects/buck/buck-review.sh" --prompt "Review for security issues" plan.md

# Send to Cursor instead of ChatGPT
"$HOME/Mac Projects/buck/buck-review.sh" --channel cursor --stdin <<'BUCKEOF'
message content
BUCKEOF

# Send to Codex (direct OpenAI API — no desktop app needed)
"$HOME/Mac Projects/buck/buck-review.sh" --channel codex --stdin <<'BUCKEOF'
message content
BUCKEOF
```

### Channels

| Channel | Target | Notes |
|---------|--------|-------|
| `a` (default) | ChatGPT main window | `AXStandardWindow` subrole |
| `b` | ChatGPT companion window | `AXSystemDialog` subrole |
| `cursor` | Cursor AI chat panel | Keyboard simulation + AX bubbles |
| `codex` | OpenAI Responses API | Direct HTTP — no desktop app needed |

The script blocks until the target responds and outputs JSON:
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
- Buck.app is always running as a menu bar app — do NOT launch it before every message
- For ChatGPT channels: ChatGPT desktop app must be open with a visible window
- For Cursor channel: Cursor must be running with chat panel open (Cmd+L), and `~/.cursor/argv.json` must contain `"force-renderer-accessibility": true`
- For Codex channel: requires `~/.buck/codex-config.json` with `api_key` field, or `OPENAI_API_KEY` environment variable
- If a `buck-review.sh` call fails with a connection/process error, launch Buck and retry:
  ```bash
  open /Applications/Buck.app && sleep 2
  ```

## Architecture

All bridges conform to `BridgeProtocol` (`findApp`, `sendMessage`, `waitForResponse`, `startNewChat`). The coordinator routes requests to the correct bridge based on the `channel` field in the inbox JSON. All bridges share the same 120s response timeout and polling logic.

### Key differences between bridges

| Aspect | ChatGPT | Cursor | Codex |
|--------|---------|--------|-------|
| Input | AXValue on AXTextArea | Brief activate + CGEvent postToPid | HTTP POST body |
| Send | AXPressAction on send button | CGEvent Enter via postToPid | URLSession request |
| Messages | AXList → AXGroup → AXStaticText | `bubble-*` domId → AXStaticText | JSON response body |
| AX init | `AXUIElementCreateApplication` | + `AXManualAccessibility` per read | None (no AX) |
| Completion | Send button reappearance + text stability | Text stability (3-4 polls) | HTTP response received |

### Source

- `Buck/Buck/BridgeProtocol.swift` — shared protocol, `BridgeError`, `BuckLog`
- `Buck/Buck/ChatGPTBridge.swift` — ChatGPT AX bridge
- `Buck/Buck/CursorBridge.swift` — Cursor AX bridge
- `Buck/Buck/CodexBridge.swift` — Codex API bridge (direct HTTP, no AX)
- `Buck/Buck/BuckCoordinator.swift` — routes inbox requests to bridges by channel
- `test-cursor-bridge.swift` — standalone Cursor test harness

## buck-notify — SMS notifications via Twilio

A separate CLI that sends SMS alerts to the user's phone via Buck's Twilio channel, and optionally waits for a reply SMS. Use this when Claude needs to reach the user who's away from the terminal.

### Modes

```bash
# Fire-and-forget info push (e.g. "X task completed")
"$HOME/Mac Projects/buck/buck-notify.sh" --info "Build passed, deploying..."

# Ask a question and wait for an SMS reply (default timeout: 10 min)
"$HOME/Mac Projects/buck/buck-notify.sh" --ask "Proceed with migration? (yes/no)"

# Ask with a custom timeout (seconds)
"$HOME/Mac Projects/buck/buck-notify.sh" --ask "Short question" --timeout 60
```

### Output

```json
{ "status": "sent|reply|error", "response": "..." }
```

- `status: sent` — info pushed (response = "sent").
- `status: reply` — user replied; response body is the reply text verbatim.
- `status: error` — timeout or API error.
- If the user doesn't reply in time, the bridge forwards the question to the ChatGPT channel and returns `response: "[via=chatgpt_fallback] <answer>"`. Callers can detect fallback by the prefix.

### SMS body tags

The outgoing SMS body is auto-prefixed so the user can tell at a glance whether a reply is expected:

- `--info "<msg>"` → phone shows `INFO-<msg>` (no reply required)
- `--ask  "<msg>"` → phone shows `QUES-<msg>` (reply requested)

These 5-char prefixes count against the 480-char length cap. Keep the actual message ≤ 475 chars to avoid truncation.

### Safety limits (enforced by the bridge)

| Limit | Default | Override |
|---|---|---|
| Max message length | **480 chars** (3 SMS segments) | `max_message_length` in `~/.buck/twilio-config.json` |
| Rate cap | **20 SMS per rolling hour** | `max_per_hour` |
| Min interval between sends | **2 s** | `min_interval_sec` |

**When calling `buck-notify.sh`:**
- Keep messages under 480 chars. Messages that exceed it are truncated with a trailing `…` and logged — they do NOT error, but you'll lose the tail, so phrase the important bit first.
- Do not fire notifications in tight loops. The 20/hour cap is persisted to `~/.buck/twilio-rate.json` and survives Buck restarts. A rate-limit violation returns `status: error` with a message telling you when the next slot frees.
- Treat SMS as a scarce channel. Only use it for (a) task completion on long-running work, or (b) decisions that actually need the user. Never for progress chatter.

### Timeouts

- Bash tool timeout for `--info`: `timeout: 90000` (90 s) is plenty.
- Bash tool timeout for `--ask`: set it to `(--timeout value + 60) * 1000` ms. Default ask is 600 s, so `timeout: 660000` ms. For tests with short custom timeouts, scale accordingly.
- Never run `--ask` in the background — you need the reply to proceed.

### Requirements

- Twilio account (SID + auth token + from-number + to-number) in `~/.buck/twilio-config.json` (mode 600).
- Buck.app running as menu bar app.
- Twilio is outbound- and inbound-capable on the `from_number`.

## BuckSpeak — Voice I/O

BuckSpeak is a separate local speak/listen tool. It does NOT use ChatGPT or `buck-review.sh`. It uses its own app (`BuckSpeak.app`) and IPC directories (`~/.buckspeak/`).

### Modes

```bash
# Speak only
"$HOME/Mac Projects/buck/buck-speak.sh" --speak --text "Hello from Claude"

# Listen only (speech recognition)
"$HOME/Mac Projects/buck/buck-speak.sh" --listen

# Speak, then listen for response
"$HOME/Mac Projects/buck/buck-speak.sh" --speak-listen --text "Hey ARIA"

# Text from stdin
echo "Hello" | "$HOME/Mac Projects/buck/buck-speak.sh" --speak --stdin
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--speak` | — | Text-to-speech only |
| `--listen` | — | Speech recognition only |
| `--speak-listen` | — | Speak first, then listen |
| `--text TEXT` | — | Text to speak |
| `--stdin` | — | Read text from stdin |
| `--voice NAME` | `Lee Premium` | macOS voice name |
| `--rate WPM` | system default | Speech rate in words per minute |
| `--listen-timeout MS` | `20000` | Max listening duration |
| `--silence-timeout MS` | `2500` | Silence detection cutoff |
| `--locale ID` | system locale | Speech recognizer locale |

### Output

JSON on stdout:
```json
{
  "status": "ok",
  "mode": "speak-listen",
  "spoken_text": "Hey ARIA",
  "heard_text": "Hello, how are you?",
  "speech_started_ms": 4210,
  "speech_ended_ms": 6840,
  "duration_ms": 6840,
  "error": null,
  "requested_voice": "Lee Premium",
  "resolved_voice": "Lee (Premium)",
  "resolved_voice_id": "com.apple.voice.premium.en-AU.Lee"
}
```

Status is `ok`, `error`, or `timeout`. Exit code 0 = success, 1 = error.

### Reliability notes

- `buck-speak.sh` auto-launches `BuckSpeak.app` if needed — no manual launch required
- Listen mode runs inside the app process so macOS microphone and speech recognition permissions are handled by the app
- Bash tool timeout: use `timeout: 60000` (60s) for speak-only, `timeout: 90000` (90s) for listen or speak-listen modes
- Wrapper timeout scales automatically based on `--listen-timeout`
