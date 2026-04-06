# Buck — Claude ↔ AI Review Bridge

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
