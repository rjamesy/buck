#!/bin/bash
# buck-review.sh — Send a plan to ChatGPT via Buck and wait for feedback
#
# Usage:
#   buck-review.sh <plan_file>              # Send file contents for review
#   buck-review.sh --text "plan text here"  # Send inline text
#   buck-review.sh --prompt "custom prompt" <plan_file>  # Custom review prompt
#   buck-review.sh --test                   # Smoke test: verify Buck + ChatGPT round-trip

set -euo pipefail

INBOX="$HOME/.buck/inbox"
OUTBOX="$HOME/.buck/outbox"
HISTORY="$HOME/.buck/history.jsonl"
HISTORY_MAX_BYTES=10485760  # 10MB
TIMEOUT=720  # 12 min — covers Buck's 2×5min windows + overhead
MAX_RETRIES=2  # retry up to 2 times on error

DEFAULT_PROMPT="Review only the plan between <plan> and </plan>. Ignore any earlier conversation.

Do not use Terminal, browser, screen, or app tools unless I explicitly ask for external verification.

First line must be exactly one of:
APPROVED
FEEDBACK

Approve only if the plan is executable as written with no hidden assumptions.

If the result is FEEDBACK, output only these sections:
Critical issues
Missing assumptions
Concrete changes

Keep each section short and specific. Do not rewrite the whole plan."

# ─── Dependency check ────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not found. Install Python 3." >&2
    exit 1
fi

# ─── Parse args ──────────────────────────────────────────────────────
PROMPT="$DEFAULT_PROMPT"
CONTENT=""
SESSION_ID=""
CHANNEL="${BUCK_CHANNEL:-}"
CALLER="${BUCK_CALLER:-}"
SMOKE_TEST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt)
            PROMPT="$2"
            shift 2
            ;;
        --text)
            CONTENT="$2"
            shift 2
            ;;
        --stdin)
            CONTENT=$(cat)
            shift
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --retries)
            MAX_RETRIES="$2"
            shift 2
            ;;
        --session)
            SESSION_ID="$2"
            shift 2
            ;;
        --channel)
            CHANNEL="$2"
            shift 2
            ;;
        --caller)
            CALLER="$2"
            shift 2
            ;;
        --test)
            SMOKE_TEST=true
            shift
            ;;
        *)
            if [[ -f "$1" ]]; then
                CONTENT=$(cat "$1")
            else
                echo "Error: File not found: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# ─── Smoke test mode ────────────────────────────────────────────────
if $SMOKE_TEST; then
    PROMPT="Reply with exactly one word: OK"
    CONTENT="Smoke test"
    TIMEOUT=60
    MAX_RETRIES=1
    echo "Running smoke test..." >&2
fi

if [[ -z "$CONTENT" ]]; then
    echo "Usage: buck-review.sh [--prompt \"...\"] [--text \"...\"] [plan_file]" >&2
    echo "       buck-review.sh --test" >&2
    exit 1
fi

# L2.1 — auto-resolve session from CWD when not explicitly set. Stable per
# project across terminal launches; buck-context keys all rows on this path.
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="$(pwd -P)"
fi

# Check Buck is running
if ! pgrep -x Buck > /dev/null 2>&1; then
    echo "Error: Buck is not running. Launch it from /Applications/Buck.app" >&2
    exit 1
fi

# Ensure directories exist
mkdir -p "$INBOX" "$OUTBOX"

# ─── buck-context bridge (L2 logging) ────────────────────────────────
BUCK_CONTEXT="$(dirname "$0")/buck-context"

# Map a buck channel name to the schema-allowed agent enum
# (user|claude|gpt|codex|buck). Cursor is treated as gpt-class for now.
bc_agent_for_channel() {
    case "${1:-}" in
        codex)  echo "codex" ;;
        cursor) echo "gpt" ;;
        *)      echo "gpt" ;;
    esac
}

# Insert a single message row into ~/.buck/memory.db via buck-context.
# Errors are swallowed — DB unavailability must never break the buck-review
# round-trip. Args:
#   $1 direction   out | in
#   $2 agent       user|claude|gpt|codex|buck
#   $3 channel     a|b|cursor|codex|""
#   $4 status      approved|feedback|error|""
#   $5 request_id
#   $6 content     (string passed via stdin to dodge arg-length limits)
bc_log_msg() {
    [[ -x "$BUCK_CONTEXT" ]] || return 0
    printf '%s' "$6" | "$BUCK_CONTEXT" message-add \
        --direction="$1" --agent="$2" \
        --channel="$3" --status="$4" --request-id="$5" \
        --session="$SESSION_ID" --content-stdin >/dev/null 2>&1 || true
}

# Scan a response body for `MEMORY[<cat>]: <content>` lines and persist each
# via `buck-context write`. This is the bidirectional path: GPT can curate
# the project's memory bank by emitting structured markers in its replies.
# Implemented in Python because macOS ships bash 3.2 with broken BASH_REMATCH
# capture groups; python3 is already a hard dep of this script.
bc_parse_memory_writes() {
    [[ -x "$BUCK_CONTEXT" ]] || return 0
    printf '%s' "$1" | python3 -c '
import re, subprocess, sys
bc, session = sys.argv[1], sys.argv[2]
text = sys.stdin.read()
for m in re.finditer(r"^MEMORY\[([a-z_]+)\]:\s*(.+?)\s*$", text, re.MULTILINE):
    cat, content = m.group(1), m.group(2).strip()
    if not content:
        continue
    subprocess.run(
        [bc, "write", cat, content,
         "--key=gpt-suggested", "--importance=6",
         f"--session={session}"],
        check=False,
    )
' "$BUCK_CONTEXT" "$SESSION_ID" 2>/dev/null || true
}

# ─── Logging helpers ────────────────────────────────────────────────

# Rotate history log if over 10MB
rotate_history() {
    if [[ -f "$HISTORY" ]]; then
        local size
        size=$(stat -f%z "$HISTORY" 2>/dev/null || echo 0)
        if [[ $size -gt $HISTORY_MAX_BYTES ]]; then
            mv "$HISTORY" "${HISTORY}.old"
            echo "History log rotated (was ${size} bytes)" >&2
        fi
    fi
}

# Log a request/response exchange to history.jsonl (atomic append)
log_exchange() {
    local request_id="$1"
    local status="$2"
    local response_text="$3"

    rotate_history

    local tmp_log
    tmp_log=$(mktemp "${HISTORY}.tmp.XXXXXX")

    python3 -c "
import json, sys
entry = {
    'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'request_id': sys.argv[1],
    'prompt': sys.argv[2][:200],
    'content': sys.argv[3][:500],
    'caller': sys.argv[4],
    'status': sys.argv[5],
    'response': sys.argv[6][:1000],
}
print(json.dumps(entry))
" "$request_id" "$PROMPT" "$CONTENT" "$CALLER" "$status" "$response_text" > "$tmp_log"

    cat "$tmp_log" >> "$HISTORY"
    rm -f "$tmp_log"

    # L2.2 — also log the inbound message into ~/.buck/memory.db. Best-effort.
    bc_log_msg in "$(bc_agent_for_channel "$CHANNEL")" "$CHANNEL" "$status" \
        "$request_id" "$response_text"
}

# Validate response JSON: must be valid JSON with required fields
validate_response() {
    local filepath="$1"

    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    if 'status' not in d:
        print('missing_status')
        sys.exit(0)
    if 'response' not in d:
        print('missing_response')
        sys.exit(0)
    # Normalize status to lowercase
    d['status'] = d['status'].strip().lower()
    # Validate status is known
    if d['status'] not in ('approved', 'feedback', 'error'):
        print('unknown_status:' + d['status'])
        sys.exit(0)
    # Write back normalized
    with open(sys.argv[1], 'w') as f:
        json.dump(d, f, indent=2)
    print('valid')
except (json.JSONDecodeError, Exception) as e:
    print('invalid_json:' + str(e))
" "$filepath"
}

# ─── Main loop ──────────────────────────────────────────────────────

# Wrap content in <plan> tags for prompt isolation, then escape for JSON
CONTENT_WRAPPED="<plan>
$CONTENT
</plan>"
CONTENT_ESCAPED=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$CONTENT_WRAPPED")
PROMPT_ESCAPED=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$PROMPT")

attempt=0
inflight_waits=0
while [ $attempt -le $MAX_RETRIES ]; do
    # Generate unique ID per attempt (UUID to avoid collisions)
    ID="review_$(uuidgen | tr '[:upper:]' '[:lower:]')_${attempt}"

    # Clean any previous response
    rm -f "$OUTBOX/$ID.json"

    # Build optional fields
    SESSION_FIELD=""
    if [[ -n "$SESSION_ID" ]]; then
        SESSION_FIELD="\"session_id\": \"$SESSION_ID\","
    fi
    CHANNEL_FIELD=""
    if [[ -n "$CHANNEL" ]]; then
        CHANNEL_FIELD="\"channel\": \"$CHANNEL\","
    fi
    CALLER_FIELD=""
    if [[ -n "$CALLER" ]]; then
        CALLER_FIELD="\"caller\": \"$CALLER\","
    fi

    # Write request (atomic: write tmp then rename)
    cat > "$INBOX/$ID.tmp" << ENDJSON
{
  "id": "$ID",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "type": "review_request",
  $SESSION_FIELD
  $CHANNEL_FIELD
  $CALLER_FIELD
  "prompt_prefix": $PROMPT_ESCAPED,
  "content": $CONTENT_ESCAPED,
  "max_rounds": 1
}
ENDJSON
    mv "$INBOX/$ID.tmp" "$INBOX/$ID.json"

    # L2.2 — log the outbound request into ~/.buck/memory.db. Stores prompt
    # + content joined so a future query has the full payload context.
    bc_log_msg out "${CALLER:-claude}" "$CHANNEL" "" "$ID" \
        "$(printf '%s\n---\n%s' "$PROMPT" "$CONTENT_WRAPPED")"

    # Display name based on channel
    DISPLAY_TARGET="ChatGPT"
    if [[ "$CHANNEL" == "cursor" ]]; then
        DISPLAY_TARGET="Cursor"
    elif [[ "$CHANNEL" == "codex" ]]; then
        DISPLAY_TARGET="Codex"
    fi

    if [ $attempt -eq 0 ]; then
        echo "Sent to Buck (id: $ID). Waiting for $DISPLAY_TARGET response..." >&2
    else
        echo "Retry $attempt/$MAX_RETRIES (id: $ID). Waiting for $DISPLAY_TARGET response..." >&2
    fi

    # Wait for response
    elapsed=0
    while [[ ! -f "$OUTBOX/$ID.json" ]] && [[ $elapsed -lt $TIMEOUT ]]; do
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [[ ! -f "$OUTBOX/$ID.json" ]]; then
        echo "Error: Timed out after ${TIMEOUT}s waiting for response" >&2
        log_exchange "$ID" "error" "Timed out after ${TIMEOUT}s"
        attempt=$((attempt + 1))
        if [ $attempt -le $MAX_RETRIES ]; then
            echo "Retrying..." >&2
            sleep 2
        fi
        continue
    fi

    # Validate response is well-formed JSON with required fields
    VALIDATION=$(validate_response "$OUTBOX/$ID.json")

    if [[ "$VALIDATION" == invalid_json* ]]; then
        echo "Error: Response is not valid JSON: $VALIDATION" >&2
        log_exchange "$ID" "error" "Invalid JSON: $VALIDATION"
        attempt=$((attempt + 1))
        if [ $attempt -le $MAX_RETRIES ]; then
            echo "Retrying..." >&2
            sleep 2
        fi
        continue
    fi

    if [[ "$VALIDATION" == missing_* ]]; then
        echo "Error: Response missing required field: $VALIDATION" >&2
        log_exchange "$ID" "error" "Missing field: $VALIDATION"
        attempt=$((attempt + 1))
        if [ $attempt -le $MAX_RETRIES ]; then
            echo "Retrying..." >&2
            sleep 2
        fi
        continue
    fi

    if [[ "$VALIDATION" == unknown_status* ]]; then
        echo "Error: Unknown status in response: $VALIDATION" >&2
        log_exchange "$ID" "error" "Unknown status: $VALIDATION"
        attempt=$((attempt + 1))
        if [ $attempt -le $MAX_RETRIES ]; then
            echo "Retrying..." >&2
            sleep 2
        fi
        continue
    fi

    # Validate response ID matches request (ignore stale responses)
    RESPONSE_ID=$(python3 -c "import json; print(json.load(open('$OUTBOX/$ID.json')).get('id',''))" 2>/dev/null || echo "")
    if [ "$RESPONSE_ID" != "$ID" ]; then
        echo "Stale response (got $RESPONSE_ID, expected $ID), ignoring..." >&2
        continue
    fi

    # Check response status
    STATUS=$(python3 -c "import json; print(json.load(open('$OUTBOX/$ID.json')).get('status',''))" 2>/dev/null || echo "")

    if [ "$STATUS" != "error" ]; then
        # Check for tool-use-only responses (GPT looked at screen but didn't answer)
        RESPONSE_TEXT=$(python3 -c "import json; print(json.load(open('$OUTBOX/$ID.json')).get('response',''))" 2>/dev/null || echo "")
        RESPONSE_LEN=${#RESPONSE_TEXT}
        if [ $RESPONSE_LEN -lt 200 ] && echo "$RESPONSE_TEXT" | grep -qE "Looked at (Terminal|Screen)|Focused on selected lines"; then
            # Strip tool-use prefixes and check if real content remains
            STRIPPED=$(echo "$RESPONSE_TEXT" | sed -E 's/^(Looked at (Terminal|Screen|the screen)|Focused on selected lines)[[:space:]]*//')
            STRIPPED_LEN=${#STRIPPED}
            if [ $STRIPPED_LEN -lt 5 ]; then
                echo "Attempt $((attempt+1)): GPT used screen tool without answering (len=$RESPONSE_LEN), retrying..." >&2
                log_exchange "$ID" "error" "Tool-use only response: $RESPONSE_TEXT"
                attempt=$((attempt + 1))
                if [ $attempt -le $MAX_RETRIES ]; then
                    sleep 3
                fi
                continue
            fi
            # Tool-use prefix + real content — strip prefix from the response file and continue
            echo "GPT used screen tool then answered (stripped prefix, keeping response)..." >&2
            python3 -c "
import json
with open('$OUTBOX/$ID.json') as f: d = json.load(f)
import re
d['response'] = re.sub(r'^(Looked at (Terminal|Screen|the screen)|Focused on selected lines)\s*', '', d['response'])
with open('$OUTBOX/$ID.json', 'w') as f: json.dump(d, f, indent=2)
"
        fi

        # Log the exchange
        RESPONSE_TEXT=$(python3 -c "import json; print(json.load(open('$OUTBOX/$ID.json')).get('response',''))" 2>/dev/null || echo "")
        log_exchange "$ID" "$STATUS" "$RESPONSE_TEXT"

        # L2.3 — scan response for `MEMORY[<cat>]: <content>` lines and
        # persist each via buck-context. Lets GPT curate project memory.
        bc_parse_memory_writes "$RESPONSE_TEXT"

        # Smoke test: validate response contains "OK"
        if $SMOKE_TEST; then
            if echo "$RESPONSE_TEXT" | grep -qi "ok"; then
                echo "Smoke test PASSED" >&2
                cat "$OUTBOX/$ID.json"
                exit 0
            else
                echo "Smoke test FAILED: expected 'OK' in response, got: $RESPONSE_TEXT" >&2
                cat "$OUTBOX/$ID.json"
                exit 1
            fi
        fi

        # Real response — output and exit
        cat "$OUTBOX/$ID.json"
        exit 0
    fi

    # Error response — log and retry
    ERROR=$(python3 -c "import json; print(json.load(open('$OUTBOX/$ID.json')).get('response','unknown'))" 2>/dev/null || echo "unknown")
    echo "Attempt $((attempt+1)) failed: $ERROR" >&2
    log_exchange "$ID" "error" "$ERROR"

    # "In flight" errors are transient — wait and retry without consuming attempt budget
    # Cap at 6 waits (60s total) to avoid infinite loop on a stuck request
    if echo "$ERROR" | grep -q "in flight"; then
        inflight_waits=$((inflight_waits + 1))
        if [ $inflight_waits -ge 6 ]; then
            echo "In-flight wait limit reached (${inflight_waits}x), treating as error" >&2
        else
            echo "Active request in progress, waiting 10s ($inflight_waits/6)..." >&2
            sleep 10
            continue
        fi
    fi

    attempt=$((attempt + 1))
    if [ $attempt -le $MAX_RETRIES ]; then
        echo "Retrying in 2s..." >&2
        sleep 2
    fi
done

# All retries exhausted — output last response if available
if [[ -f "$OUTBOX/$ID.json" ]]; then
    log_exchange "$ID" "error" "All retries exhausted"
    cat "$OUTBOX/$ID.json"
    exit 1
else
    log_exchange "$ID" "error" "All retries exhausted with no response"
    echo '{"status":"error","response":"All retries exhausted with no response"}'
    exit 1
fi
