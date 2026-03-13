#!/bin/bash
# buck-review.sh — Send a plan to ChatGPT via Buck and wait for feedback
#
# Usage:
#   buck-review.sh <plan_file>              # Send file contents for review
#   buck-review.sh --text "plan text here"  # Send inline text
#   buck-review.sh --prompt "custom prompt" <plan_file>  # Custom review prompt

set -euo pipefail

INBOX="$HOME/.buck/inbox"
OUTBOX="$HOME/.buck/outbox"
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

# Parse args
PROMPT="$DEFAULT_PROMPT"
CONTENT=""
SESSION_ID=""
CHANNEL="${BUCK_CHANNEL:-}"

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

if [[ -z "$CONTENT" ]]; then
    echo "Usage: buck-review.sh [--prompt \"...\"] [--text \"...\"] [plan_file]" >&2
    exit 1
fi

# Check Buck is running
if ! pgrep -x Buck > /dev/null 2>&1; then
    echo "Error: Buck is not running. Launch it from /Applications/Buck.app" >&2
    exit 1
fi

# Ensure directories exist
mkdir -p "$INBOX" "$OUTBOX"

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

    # Write request (atomic: write tmp then rename)
    cat > "$INBOX/$ID.tmp" << ENDJSON
{
  "id": "$ID",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "type": "review_request",
  $SESSION_FIELD
  $CHANNEL_FIELD
  "prompt_prefix": $PROMPT_ESCAPED,
  "content": $CONTENT_ESCAPED,
  "max_rounds": 1
}
ENDJSON
    mv "$INBOX/$ID.tmp" "$INBOX/$ID.json"

    if [ $attempt -eq 0 ]; then
        echo "Sent to Buck (id: $ID). Waiting for ChatGPT response..." >&2
    else
        echo "Retry $attempt/$MAX_RETRIES (id: $ID). Waiting for ChatGPT response..." >&2
    fi

    # Wait for response
    elapsed=0
    while [[ ! -f "$OUTBOX/$ID.json" ]] && [[ $elapsed -lt $TIMEOUT ]]; do
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [[ ! -f "$OUTBOX/$ID.json" ]]; then
        echo "Error: Timed out after ${TIMEOUT}s waiting for response" >&2
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
        # Real response — output and exit
        cat "$OUTBOX/$ID.json"
        exit 0
    fi

    # Error response — log and retry
    ERROR=$(python3 -c "import json; print(json.load(open('$OUTBOX/$ID.json')).get('response','unknown'))" 2>/dev/null || echo "unknown")
    echo "Attempt $((attempt+1)) failed: $ERROR" >&2

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
    cat "$OUTBOX/$ID.json"
    exit 1
else
    echo '{"status":"error","response":"All retries exhausted with no response"}'
    exit 1
fi
