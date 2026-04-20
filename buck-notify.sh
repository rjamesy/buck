#!/bin/bash
# buck-notify.sh — Send an SMS notification via Buck's Twilio bridge.
#
# Phase 1 (this file): info-push only. Phase 2 adds --ask with reply polling;
# Phase 3 adds ChatGPT fallback on timeout.
#
# Usage:
#   buck-notify.sh --info "<message>"          # Fire-and-forget SMS
#
# Output: JSON on stdout — {"status":"sent|error", "response":"..."}
# Exit: 0 on success, 1 on error/timeout.

set -euo pipefail

INBOX="$HOME/.buck/inbox"
OUTBOX="$HOME/.buck/outbox"
TIMEOUT=60   # seconds — Phase 1 info path returns immediately after Twilio POST

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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --info)
            MODE="info"
            MESSAGE="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            echo "Usage: buck-notify.sh --info \"<message>\"" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$MODE" || -z "$MESSAGE" ]]; then
    echo "Usage: buck-notify.sh --info \"<message>\"" >&2
    exit 1
fi

# ─── Preconditions ──────────────────────────────────────────────────
if ! pgrep -x Buck > /dev/null 2>&1; then
    echo "Error: Buck is not running. Launch it from /Applications/Buck.app" >&2
    exit 1
fi

mkdir -p "$INBOX" "$OUTBOX"

# ─── Build request ──────────────────────────────────────────────────
ID="notify_$(uuidgen | tr '[:upper:]' '[:lower:]')"
PROMPT_PREFIX="[BUCK-MODE:${MODE}]"
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

echo "Sent to Buck (id: $ID). Waiting for Twilio..." >&2

# ─── Wait for response ──────────────────────────────────────────────
elapsed=0
while [[ ! -f "$OUTBOX/$ID.json" ]] && [[ $elapsed -lt $TIMEOUT ]]; do
    sleep 2
    elapsed=$((elapsed + 2))
done

if [[ ! -f "$OUTBOX/$ID.json" ]]; then
    echo "Error: Timed out after ${TIMEOUT}s" >&2
    echo "{\"status\":\"error\",\"response\":\"Timed out after ${TIMEOUT}s\"}"
    exit 1
fi

# Normalise: Buck's ReviewResponse.status is {approved|feedback|error}. Phase 1 only
# cares about success (SMS accepted by Twilio). If TwilioBridge returned "sent",
# relabel status as "sent" in the output for clarity.
python3 - "$OUTBOX/$ID.json" << 'PYEOF'
import json, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
# Strip Buck's compact trailer so the response is just the bridge's output.
resp = d.get("response", "")
for trailer in ("\n\n[BUCK: Ready for compact]", "[BUCK: Ready for compact]"):
    if resp.endswith(trailer):
        resp = resp[: -len(trailer)].rstrip()
        break
d["response"] = resp
# Relabel success: TwilioBridge returns "sent" on successful POST.
if resp.strip() == "sent" and d.get("status") != "error":
    d["status"] = "sent"
print(json.dumps(d, indent=2))
PYEOF

# Exit code based on (possibly relabelled) status
STATUS=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('status',''))" "$OUTBOX/$ID.json" 2>/dev/null || echo "")
if [[ "$STATUS" == "error" ]]; then
    exit 1
fi
exit 0
