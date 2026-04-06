# Buck Teams — Design Plan

> 4-way AI group chat: User + Claude + Codex + GPT
> Planned by Claude + GPT | 2026-03-21

---

## 1. Overview

Buck Teams is a macOS SwiftUI app that enables real-time group chat between a human user and three AI participants (Claude, Codex, GPT). It builds on Buck's existing ChatGPT bridge but adds multi-participant routing, presence awareness, and a 3-column UI.

**Core principle**: File-based IPC for CLI agents (Claude, Codex), AX API for GPT, direct UI for user. One shared chat log as single source of truth.

---

## 2. What Gets Created

| Item | Source | Notes |
|------|--------|-------|
| **Buck v3** (Xcode project) | Copy of `Buck/` | Becomes Buck Teams app |
| **BuckSpeak v3** (Xcode project) | Copy of `BuckSpeak/` | Voice I/O for Teams context |
| **buck-teams.sh** | New script | CLI for Claude/Codex to join, send, poll, follow |
| **BUCK-TEAMS-PLAN.md** | This document | Design reference |

**Original Buck and BuckSpeak apps are NOT modified.**

---

## 3. Architecture

### 3.1 Runtime Directories

```
~/.buckteams/
├── chat.jsonl                    # Single source of truth (append-only, NDJSON)
├── chat.{timestamp}.jsonl        # Rotated archives (keep last 2)
├── chat.jsonl.lock               # flock target for atomic appends
├── decisions.md                  # Human-readable decisions (column 3)
├── session.json                  # Current session metadata
├── staging/                      # Agent message submissions (pre-seq)
│   └── {agent}_{msg_id}.json    # Coordinator picks up, assigns seq, appends
├── participants/
│   ├── claude.json               # Presence + status (exact filename)
│   ├── codex.json                # Presence + status (exact filename)
│   ├── gpt.json                  # Presence + status (exact filename)
│   └── user.json                 # Presence + status (exact filename)
└── inbox/
    ├── claude/
    │   └── ping                  # Touch file = "new messages in chat log"
    ├── codex/
    │   └── ping                  # Touch file = "new messages in chat log"
    └── gpt/                      # (unused — GPT routed via AX bridge)
```

**Session state file** (`session.json`):
```json
{
  "session_id": "teams_uuid",
  "active": true,
  "created_at": "2026-03-21T10:00:00Z",
  "ended_at": null,
  "system_prompt": "You are an AI participating in a group chat...",
  "current_seq": 42,
  "participants": ["user", "claude", "codex", "gpt"]
}
```

**Single active session enforced**: Only one session can be active at a time. `--start-session` fails if `session.json` has `active: true`.

### 3.2 Message Schema

Every message in `chat.jsonl` is one newline-delimited JSON line:

```json
{
  "id": "msg_uuid",
  "seq": 42,
  "session_id": "teams_uuid",
  "timestamp": "2026-03-21T10:30:00Z",
  "from": "claude",
  "to": "all",
  "type": "chat",
  "content": "I think we should use a ring buffer here.",
  "priority": "normal",
  "source": "agent",
  "reply_to": 40
}
```

| Field | Values | Notes |
|-------|--------|-------|
| `id` | UUID string | Unique message identifier |
| `seq` | integer | **Coordinator-assigned only** — agents must NOT set this. Monotonically increasing per session |
| `session_id` | UUID string | Current session. Agents ignore messages from other sessions |
| `from` | `claude`, `codex`, `gpt`, `user`, `system` | Who sent it |
| `to` | `all`, `claude`, `codex`, `gpt`, `user` | Recipient |
| `type` | `chat`, `question`, `response`, `decision`, `system` | Message type |
| `priority` | `normal`, `high` | User messages = high |
| `source` | `ui`, `agent`, `bridge` | Origin channel |
| `reply_to` | integer or null | Seq number of message being replied to (for correlation) |

**Seq authority**: Only TeamsCoordinator assigns `seq` numbers. Agents submit messages without `seq` — the coordinator reads the submission, assigns the next seq, and appends to `chat.jsonl`.

**Append contract**: All writes to `chat.jsonl` go through the coordinator. Agents write to a staging file (`~/.buckteams/staging/{agent}_{id}.json`), coordinator picks it up, assigns seq, appends with `flock`, touches wake signals. The UI also submits through the coordinator — never writes `chat.jsonl` directly.

### 3.3 Participant Status File

`participants/{name}.json`:

```json
{
  "online": true,
  "mode": "idle",
  "session_id": "teams_uuid",
  "last_seen_seq": 41,
  "heartbeat": "2026-03-21T10:30:00Z"
}
```

**Status modes → LED colours**:

| Mode | Colour | Meaning |
|------|--------|---------|
| `idle` | Green | In session, not active |
| `participating` | Yellow | Actively in conversation |
| `thinking` | Orange | Processing a response |
| `sending` | Blue | Sending a message |
| `waiting` | Purple | Waiting for reply to own message |
| `reading` | Red | Reading a response from chat |
| `silent` | Grey | Off / not participating |

### 3.4 Prefix Protocol

All messages injected into GPT and parsed from GPT use strict prefixes:

```
SYSTEM: {text}          — system/session messages
USER: {text}            — user messages (priority)
CLAUDE: {text}          — from Claude
CODEX: {text}           — from Codex
GPT: {text}             — from GPT (added by parser if missing)
ALL QUESTION: {text}    — asking everyone
ALL RESPONSE: {text}    — responding to group
{NAME} QUESTION: {text} — directed question
{NAME} RESPONSE: {text} — directed response
DECISION: {text}        — agreed outcome
```

GPT responses are parsed for valid prefixes. Invalid/missing prefix → default to `GPT:` to all. Hallucinated prefixes (GPT pretending to be CLAUDE:) are stripped.

---

## 4. Communication Paths

### 4.1 GPT — AX API Bridge (existing pattern)

```
TeamsCoordinator → GPT message queue (serial) → ChatGPTBridge → ChatGPT desktop app (AX API)
                                               ← Response polling (AX text collection)
```

- Copied from Buck's ChatGPTBridge into v3
- Messages prefixed before injection
- Responses parsed for prefixes and routed back to chat log
- **Serial queue**: GPT injection is queued (one at a time) to prevent overlapping AX operations. If multiple messages target GPT simultaneously, they queue and inject in order.
- **Response correlation**: Each injected message records its seq. GPT's response gets `reply_to` set to that seq.

### 4.2 Claude / Codex — File IPC

```
Claude/Codex → buck-teams.sh --send "msg" → staging/{agent}_{id}.json
            ← Coordinator picks up staging → assigns seq → appends chat.jsonl
            ← Coordinator touches inbox/{agent}/ping (wake signal)
            ← buck-teams.sh --poll/--follow ← read from chat.jsonl
```

- Both use identical `buck-teams.sh` interface
- Agent identifies itself via `--agent claude` or `--agent codex`
- Non-blocking poll or blocking follow mode
- Agents persist `last_seen_seq` locally in their participant file to survive restarts
- On poll: read from `last_seen_seq + 1` to end of chat.jsonl

### 4.3 User — Direct UI

```
User types in SwiftUI text field → TeamsCoordinator → chat.jsonl
chat.jsonl updates → SwiftUI bindings → chat bubbles update
```

### 4.4 Message Routing Flow

```
1. Message arrives:
   ├── From agent: staging/{agent}_{id}.json detected by FileWatcher
   ├── From GPT: ChatGPTBridge response polling
   └── From User: SwiftUI → TeamsCoordinator.submit()
2. TeamsCoordinator validates message (JSON structure, valid from/to)
3. Assigns seq number (atomic increment, coordinator is sole seq authority)
4. Appends to chat.jsonl under flock
5. Deletes staging file (if from agent)
6. Routes based on "to" field:
   ├── "all" → route to all other participants (except sender)
   ├── specific name → route only to that participant
   └── Never route back to sender (loop prevention)
7. Routing per participant:
   ├── GPT: enqueue to GPT injection queue (serial)
   ├── Claude/Codex: touch inbox/{agent}/ping (wake signal)
   └── User: update SwiftUI @Published state
8. Track msg_id in routed set (idempotent, route only once)
```

---

## 5. UI Layout (3 Columns)

### Column 1 — Sidebar (Left)

**Row 1: Participants Panel**
- Card per participant (User, Claude, Codex, GPT)
- LED indicator (coloured circle matching status mode)
- On/Off toggle switch per participant
  - On = participates in chat (can send/receive)
  - Off = sits idle, grey LED, does not participate
- All participants aware of who else is in the session

**Row 2: Debug Panel**
- Message counts per participant
- Latencies (GPT bridge response time)
- Errors and warnings
- Current seq number

**Row 3: System Prompt**
- Editable text area
- Default prompt:
  > "You are an AI participating in a group chat session with other AIs and a human user. Purpose: collaborative problem-solving. Rules: be concise, stay on topic, respect user priority. Challenge ideas constructively. Goals: reach agreed decisions. The user is king — their instructions override all. Agreed decisions go into the Decisions panel."
- Applied to GPT as first message on session start
- Claude/Codex read it from the chat log (type=system, seq=1)

**Row 4: Controls**
- Start Session (creates session, broadcasts join)
- Stop Session (broadcasts leave, archives)
- Reset (clear chat, decisions, restart)
- Pause/Resume (temporarily halt routing)

### Column 2 — Chat (Center)

- Chat bubbles (colour-coded per participant)
  - User: blue
  - Claude: orange
  - Codex: green
  - GPT: purple
  - System: grey
- Directed messages shown with `→ {recipient}` indicator
- User text input at bottom
  - Inserts as `USER: message` with priority=high
  - User is king: overrides, guides conversation if drifting
- Controls: Copy All, Clear Chat, Export to .md

### Column 3 — Decisions (Right)

- Displays contents of `decisions.md`
- Updated when:
  - Any participant sends type=decision message
  - Decision rule: ≥2 agents agree OR user confirms
- Each decision shown as a card with timestamp and who proposed/agreed
- Controls: Copy All, Clear, Export to .md

---

## 6. buck-teams.sh — CLI Interface

```bash
# Session management
buck-teams.sh --start-session             # Create new session (fails if one active)
buck-teams.sh --join --agent claude       # Join existing session
buck-teams.sh --leave --agent claude      # Leave session
buck-teams.sh --session-info              # Get session state JSON

# Messaging (writes to staging/, coordinator assigns seq)
buck-teams.sh --send "msg" --agent claude           # Send to all
buck-teams.sh --send-to gpt "msg" --agent claude    # Direct message
buck-teams.sh --decide "text" --agent claude         # Propose decision

# Reading
buck-teams.sh --poll --agent claude                  # Non-blocking: new messages since last_seen_seq
buck-teams.sh --follow --agent claude                # Blocking tail (streams NDJSON lines)
buck-teams.sh --since 42 --agent claude              # Messages since specific seq

# Status
buck-teams.sh --status thinking --agent claude       # Update LED status + heartbeat
buck-teams.sh --who                                  # List participants + status
```

**Send mechanism**: `--send` writes a staging file to `~/.buckteams/staging/{agent}_{msg_id}.json`. The coordinator watches this directory, picks up the file, assigns seq, appends to chat.jsonl, deletes the staging file, and touches wake signals. This ensures the coordinator is the sole writer of chat.jsonl.

**Poll mechanism**: Reads `last_seen_seq` from `participants/{agent}.json`, scans chat.jsonl from that offset, returns new messages as NDJSON, updates `last_seen_seq`. Agent persists this across restarts.

**Follow mechanism**: Like poll but blocks. Uses `fswatch` or polling (2s interval) on `inbox/{agent}/ping`. On wake signal: read new messages, output, clear ping file, continue waiting.

**Output format** (JSON per line for --poll/--follow):
```json
{"id":"msg_1","seq":43,"from":"codex","to":"all","type":"chat","content":"..."}
```

---

## 7. Agent Loop Contract

Every CLI agent (Claude, Codex) must:

1. **Join** the session on startup (`--join`)
2. **Poll or follow** the chat log for new messages
3. **Update heartbeat** every 10s (implicit on `--poll`, explicit via `--status`)
4. **Respect user priority** — if a high-priority message arrives, respond to it next
5. **Not spam** — rate limited to 1 message per 2 seconds per agent (coordinator enforces)
6. **Not echo** — never respond to own messages
7. **Not self-reply** — track last_seen_seq, only process new messages
8. **Reference context** — when responding to a specific message, reference its seq
9. **Leave cleanly** on disconnect (`--leave`)

Coordinator marks agent as grey (stale) if heartbeat > 30s old.

---

## 8. GPT Response Parser

GPT responses are parsed by TeamsCoordinator:

1. Split response by lines
2. Check each line for valid prefix: `CLAUDE`, `CODEX`, `USER`, `ALL`, `DECISION`, `SYSTEM`
3. Valid prefix → create directed message with correct `to` field
4. No valid prefix → wrap as `GPT:` to `all`
5. Strip hallucinated prefixes (GPT claiming to be another participant)
6. `DECISION:` lines → also append to `decisions.md`

---

## 9. Session Lifecycle

```
[Start]
  │
  ├── User clicks "Start" in UI  ─── OR ─── Agent calls --start-session
  │
  ▼
[Session Created]
  │  session.json written (id, started_at, system_prompt)
  │  System prompt injected into GPT (first message)
  │  type=system message: "Teams session started"
  │
  ▼
[Active Chat]
  │  Participants join/leave
  │  Messages routed by TeamsCoordinator
  │  Decisions recorded
  │  Log rotated at 10MB
  │
  ├── User clicks "Stop"  ─── OR ─── All agents leave
  │
  ▼
[Session Ended]
  │  type=system message: "Teams session ended"
  │  session.json updated (ended_at)
  │  Chat log archived
  │  decisions.md preserved
```

---

## 10. Concurrency & Safety

| Concern | Solution |
|---------|----------|
| Chat log concurrent appends | `flock` on `chat.jsonl.lock` — coordinator is sole writer |
| Participant file concurrent writes | Atomic write (.tmp → rename) |
| Message routing duplication | Routed set (msg_id tracking, in-memory) |
| Echo/loop prevention | Never route to sender + agent tracks last_seen_seq |
| GPT bridge concurrency | Single ChatGPTBridge instance, serial DispatchQueue |
| GPT injection overlap | Message queue — one injection at a time, FIFO order |
| Rate limiting | Queue + delay (not drop). 1 msg / 2s / agent. User exempt |
| Stale participants | Heartbeat timeout (30s) → grey status |
| Log growth | Rotate at 10MB, keep current + last 2 archives |
| Log rotation for agents | On rotation: write `type=system` message with new file path. Agents detect rotation via system message and reset file offset |
| Malformed JSON in chat.jsonl | Skip line, log warning in debug panel. Do not halt |
| Failed GPT injection | Retry once. If still fails, write `type=system` error message to chat log. Mark GPT status as red |
| File lock failure | Retry with exponential backoff (100ms, 200ms, 400ms). After 3 failures, log error, skip message |
| Trust boundary | Single-user local system. No auth. All participants trusted. Note: any process can write to `~/.buckteams/` — acceptable for local dev tool |
| Single active session | `session.json` enforces one active session. `--start-session` rejects if active |

### 10.1 Decision Consensus Tracking

To detect "≥2 agents agree":
1. When a participant sends `type=decision`, coordinator records it as a **proposal** with a content hash
2. If another participant sends a decision with the same content hash (or responds with `AGREED` to the same seq), it counts as a second agreement
3. At 2 agreements (or 1 user confirmation), coordinator writes to `decisions.md` and broadcasts `type=system` confirmation
4. Proposals without consensus within 10 messages expire silently

---

## 11. Swift Components (Buck v3)

| File | Responsibility |
|------|---------------|
| `BuckTeamsApp.swift` | SwiftUI entry point, 3-column layout, window (not menu bar) |
| `TeamsCoordinator.swift` | Central message bus, routing, session management, seq authority |
| `ChatGPTBridge.swift` | AX API bridge to ChatGPT (copied from Buck, adapted for prefixes) |
| `GPTResponseParser.swift` | Parse prefixed responses from GPT, strip hallucinated prefixes |
| `GPTMessageQueue.swift` | Serial queue for GPT injections (prevents overlap) |
| `ParticipantManager.swift` | Presence tracking, heartbeat monitoring, status LEDs |
| `ChatLogStore.swift` | Read/write/tail chat.jsonl, flock management, rotation |
| `StagingWatcher.swift` | Watch `~/.buckteams/staging/` for agent message submissions |
| `DecisionStore.swift` | Read/write decisions.md, consensus tracking (content hash) |
| `FileWatcher.swift` | Watch directories for changes (copied from Buck, adapted) |
| `SessionManager.swift` | Session lifecycle (create, end, enforce single-active) |
| `Models.swift` | TeamMessage, Participant, Session, DecisionProposal codables |
| `ChatBubbleView.swift` | Per-message bubble UI (colour-coded per participant) |
| `ParticipantCardView.swift` | Participant card with LED indicator + on/off toggle |
| `DecisionCardView.swift` | Decision display card with timestamp and proposer |
| `DebugPanelView.swift` | Message counts, latencies, errors, current seq |
| `SystemPromptView.swift` | Editable system prompt text area |
| `ControlsView.swift` | Start/Stop/Reset/Pause buttons |

---

## 12. Phased Implementation

### Phase 1 — Foundation
- Copy Buck → Buck v3 (Xcode project)
- Copy BuckSpeak → BuckSpeak v3
- Set up `~/.buckteams/` directory structure
- Define Models.swift (TeamMessage, Participant, Session)
- Implement ChatLogStore (append, read, tail, flock, rotation)

### Phase 2 — Coordinator & Routing
- Implement TeamsCoordinator (event loop, message routing)
- Implement ParticipantManager (presence, heartbeat, status)
- Adapt ChatGPTBridge for Teams (prefix injection, response parsing)
- Implement GPTResponseParser
- Implement DecisionStore

### Phase 3 — CLI Script
- Implement buck-teams.sh (all commands)
- Test with mock messages
- Test join/leave/poll/follow/send lifecycle

### Phase 4 — UI
- 3-column SwiftUI layout
- Column 1: participant cards, debug panel, system prompt, controls
- Column 2: chat bubbles, user input
- Column 3: decisions panel
- Wire UI to TeamsCoordinator via @Published bindings

### Phase 5 — Integration
- End-to-end: User + Claude + GPT in live session
- End-to-end: User + Codex + GPT in live session
- 4-way: all participants
- Agent-initiated sessions
- Stress test rate limiting, heartbeat, log rotation

### Phase 6 — Polish
- Export to .md (chat + decisions)
- Copy buttons
- Error handling and edge cases
- BuckSpeak v3 integration (voice in Teams context)

---

## 13. Key Design Decisions (Claude + GPT Agreed)

1. **Single source of truth**: `chat.jsonl` is the canonical chat log. No per-participant outbox. Inbox used only for wake signals.
2. **Codex = Claude**: Both use file IPC via `buck-teams.sh`. No AX API for Codex.
3. **Free-for-all turns**: No strict speaking order. User has priority. Agents must not self-reply or spam.
4. **Decision rule**: ≥2 agents agree OR user confirms before writing to decisions.
5. **Coordinator owns all routing**: UI is state display only. No logic in views.
6. **Originals untouched**: Buck and BuckSpeak are not modified. v3 copies are independent.

---

## 14. Open Questions

1. Should the app be a menu bar app (like Buck) or a full window app? *Recommendation: full window app — the 3-column layout needs real estate.*
2. Maximum number of concurrent sessions? *Recommendation: 1 active session at a time for v1.*
3. Should BuckSpeak v3 announce messages aloud? *Recommendation: optional, user-toggled.*

---

*Plan created by Claude + GPT collaborative planning session.*
*Ready for user approval before implementation begins.*
