#!/bin/bash
# buck-notify.sh — Send an SMS notification via Buck's Twilio bridge.
#
# Phase 1: --info (fire-and-forget).
# Phase 2: --ask (wait for SMS reply, default 10 min).
# Phase 3: adds a ChatGPT fallback on timeout.
#
# Usage:
#   buck-notify.sh --info "<message>"                     # Fire-and-forget SMS
#   buck-notify.sh --ask  "<question>" [--timeout 600]    # Wait for reply
#
# Output: JSON on stdout — {"status":"sent|reply|error", "response":"..."}
# Exit: 0 on success, 1 on error/timeout.

set -euo pipefail

INBOX="$HOME/.buck/inbox"
OUTBOX="$HOME/.buck/outbox"

# ─── Dependency check ───────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not found." >&2
    exit 1
fi
if ! command -v uuidgen &>/dev/null; then
    echo "Error: uuidgen is required but not found." >&2
    exit 1
fi

# ─── Parse args ─────────────────────────────────────────────────────
MODE=""
MESSAGE=""
TIMEOUT=""          # user-supplied override; defaults are mode-dependent below

while [[ $# -gt 0 ]]; do
    case "$1" in
        --info)
            MODE="info"
            MESSAGE="$2"
            shift 2
            ;;
        --ask)
            MODE="ask"
            MESSAGE="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,13p' "$0"
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            echo "Usage: buck-notify.sh {--info|--ask} \"<message>\" [--timeout 600]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$MODE" || -z "$MESSAGE" ]]; then
    echo "Usage: buck-notify.sh {--info|--ask} \"<message>\" [--timeout 600]" >&2
    exit 1
fi

# Default timeouts per mode
if [[ -z "$TIMEOUT" ]]; then
    if [[ "$MODE" == "ask" ]]; then
        TIMEOUT=600
    else
        TIMEOUT=60
    fi
fi

# Shell poll needs some headroom over the bridge's internal timeout so we don't
# time out before the bridge can report its own timeout back.
SHELL_WAIT=$((TIMEOUT + 30))

# ─── Preconditions ──────────────────────────────────────────────────
if ! pgrep -x Buck > /dev/null 2>&1; then
    echo "Error: Buck is not running. Launch it from /Applications/Buck.app" >&2
    exit 1
fi

mkdir -p "$INBOX" "$OUTBOX"

# ─── Build request ──────────────────────────────────────────────────
ID="notify_$(uuidgen | tr '[:upper:]' '[:lower:]')"
# Embed the ask-timeout in the mode tag so the bridge knows how long to poll.
if [[ "$MODE" == "ask" ]]; then
    PROMPT_PREFIX="[BUCK-MODE:ask:${TIMEOUT}]"
else
    PROMPT_PREFIX="[BUCK-MODE:info]"
fi
# Each notification is a one-shot, not a conversation. Give it a unique session
# so Buck's compact-threshold logic (≥10 turns in rolling window) never triggers.
SESSION_ID="$ID"

# JSON-escape the message and prefix
MESSAGE_ESCAPED=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$MESSAGE")
PROMPT_ESCAPED=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$PROMPT_PREFIX")

# Clear any stale response
rm -f "$OUTBOX/$ID.json"

# Atomic write: .tmp → rename
cat > "$INBOX/$ID.tmp" << ENDJSON
{
  "id": "$ID",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "type": "notify_request",
  "channel": "twilio",
  "caller": "claude",
  "session_id": "$SESSION_ID",
  "prompt_prefix": $PROMPT_ESCAPED,
  "content": $MESSAGE_ESCAPED,
  "max_rounds": 1
}
ENDJSON
mv "$INBOX/$ID.tmp" "$INBOX/$ID.json"

if [[ "$MODE" == "ask" ]]; then
    echo "Sent to Buck (id: $ID). Waiting up to ${TIMEOUT}s for SMS reply..." >&2
else
    echo "Sent to Buck (id: $ID). Waiting for Twilio..." >&2
fi

# ─── Wait for response ──────────────────────────────────────────────
elapsed=0
while [[ ! -f "$OUTBOX/$ID.json" ]] && [[ $elapsed -lt $SHELL_WAIT ]]; do
    sleep 2
    elapsed=$((elapsed + 2))
done

if [[ ! -f "$OUTBOX/$ID.json" ]]; then
    echo "Error: Timed out after ${SHELL_WAIT}s (shell wait)" >&2
    echo "{\"status\":\"error\",\"response\":\"Timed out after ${SHELL_WAIT}s (shell wait)\"}"
    exit 1
fi

# Normalise: Buck's ReviewResponse.status enum is {approved|feedback|error}.
# Relabel based on mode:
#   info + response "sent"   → status "sent"
#   ask  + no error          → status "reply"
# Also strip Buck's [BUCK: Ready for compact] trailer if present.
python3 - "$OUTBOX/$ID.json" "$MODE" << 'PYEOF'
import json, sys
p, mode = sys.argv[1], sys.argv[2]
with open(p) as f:
    d = json.load(f)
resp = d.get("response", "")
for trailer in ("\n\n[BUCK: Ready for compact]", "[BUCK: Ready for compact]"):
    if resp.endswith(trailer):
        resp = resp[: -len(trailer)].rstrip()
        break
d["response"] = resp
if d.get("status") != "error":
    if mode == "info" and resp.strip() == "sent":
        d["status"] = "sent"
    elif mode == "ask":
        d["status"] = "reply"
print(json.dumps(d, indent=2))
PYEOF

STATUS=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('status',''))" "$OUTBOX/$ID.json" 2>/dev/null || echo "")
if [[ "$STATUS" == "error" ]]; then
    exit 1
fi
exit 0
