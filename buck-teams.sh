#!/bin/bash
# buck-teams.sh — CLI for Claude/Codex to participate in Buck Teams sessions
# Usage: buck-teams.sh --join --agent claude
#        buck-teams.sh --send "message" --agent claude
#        buck-teams.sh --poll --agent claude
#        buck-teams.sh --follow --agent claude
set -euo pipefail

TEAMS_ROOT="$HOME/.buckteams"
CHAT_LOG="$TEAMS_ROOT/chat.jsonl"
STAGING="$TEAMS_ROOT/staging"
PARTICIPANTS="$TEAMS_ROOT/participants"
SESSION_FILE="$TEAMS_ROOT/session.json"
INBOX="$TEAMS_ROOT/inbox"

# Ensure directories exist
mkdir -p "$STAGING" "$PARTICIPANTS" "$INBOX"

# --- Argument parsing ---
ACTION=""
AGENT=""
MESSAGE=""
TARGET="all"
STATUS_MODE=""
SINCE_SEQ=0
MSG_TYPE="chat"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start-session)  ACTION="start-session"; shift ;;
        --join)           ACTION="join"; shift ;;
        --leave)          ACTION="leave"; shift ;;
        --send)           ACTION="send"; MESSAGE="$2"; shift 2 ;;
        --send-to)        ACTION="send"; TARGET="$2"; MESSAGE="$3"; shift 3 ;;
        --decide)         ACTION="send"; MSG_TYPE="decision"; TARGET="all"; MESSAGE="$2"; shift 2 ;;
        --poll)           ACTION="poll"; shift ;;
        --follow)         ACTION="follow"; shift ;;
        --listen)         ACTION="listen"; shift ;;
        --since)          SINCE_SEQ="$2"; shift 2 ;;
        --status)         ACTION="status"; STATUS_MODE="$2"; shift 2 ;;
        --who)            ACTION="who"; shift ;;
        --session-info)   ACTION="session-info"; shift ;;
        --agent)          AGENT="$2"; shift 2 ;;
        --help)
            echo "Usage: buck-teams.sh [action] --agent [name]"
            echo ""
            echo "Actions:"
            echo "  --start-session           Create new session"
            echo "  --join                    Join existing session"
            echo "  --leave                   Leave session"
            echo "  --send \"msg\"              Send to all"
            echo "  --send-to name \"msg\"      Direct message"
            echo "  --decide \"text\"           Propose decision"
            echo "  --poll                    Get new messages (non-blocking)"
            echo "  --follow                  Tail chat (blocking, polling)"
            echo "  --listen                  Event-driven listener (fswatch, zero CPU when idle)"
            echo "  --since N                 Messages since seq N"
            echo "  --status mode             Update status (idle|participating|thinking|sending|waiting|reading|silent)"
            echo "  --who                     List participants"
            echo "  --session-info            Get session state"
            echo ""
            echo "  --agent name              Identify as claude|codex"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# --- Helper functions ---

iso_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

gen_uuid() {
    python3 -c "import uuid; print(uuid.uuid4())"
}

read_session() {
    if [[ -f "$SESSION_FILE" ]]; then
        cat "$SESSION_FILE"
    else
        echo "{}"
    fi
}

get_session_id() {
    local session
    session=$(read_session)
    echo "$session" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || echo ""
}

is_session_active() {
    local session
    session=$(read_session)
    echo "$session" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('active') else 'false')" 2>/dev/null || echo "false"
}

get_last_seen_seq() {
    local pfile="$PARTICIPANTS/${AGENT}.json"
    if [[ -f "$pfile" ]]; then
        python3 -c "import json; d=json.load(open('$pfile')); print(d.get('last_seen_seq', 0))" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

update_participant() {
    local pfile="$PARTICIPANTS/${AGENT}.json"
    local tmpfile="$PARTICIPANTS/${AGENT}.tmp"
    local online="${1:-true}"
    local mode="${2:-idle}"
    local session_id="${3:-}"
    local last_seen="${4:-0}"

    cat > "$tmpfile" <<PEOF
{
    "name": "$AGENT",
    "online": $online,
    "mode": "$mode",
    "session_id": "$session_id",
    "last_seen_seq": $last_seen,
    "heartbeat": "$(iso_timestamp)"
}
PEOF
    mv "$tmpfile" "$pfile"
}

write_staging() {
    local msg_id="msg_$(gen_uuid)"
    local session_id
    session_id=$(get_session_id)
    local staging_file="$STAGING/${AGENT}_${msg_id}.json"

    cat > "$staging_file" <<SEOF
{
    "id": "$msg_id",
    "from": "$AGENT",
    "to": "$TARGET",
    "type": "$MSG_TYPE",
    "content": $(python3 -c "import json; print(json.dumps('''$MESSAGE'''))"),
    "priority": "normal",
    "source": "agent",
    "reply_to": null,
    "session_id": "$session_id"
}
SEOF
    echo "$msg_id"
}

# Use python for safe JSON encoding of message content
write_staging_safe() {
    local msg_id="msg_$(gen_uuid)"
    local session_id
    session_id=$(get_session_id)
    local staging_file="$STAGING/${AGENT}_${msg_id}.json"

    python3 -c "
import json, sys
msg = {
    'id': '$msg_id',
    'from': '$AGENT',
    'to': '$TARGET',
    'type': '$MSG_TYPE',
    'content': sys.stdin.read(),
    'priority': 'normal',
    'source': 'agent',
    'reply_to': None,
    'session_id': '$session_id'
}
with open('$staging_file', 'w') as f:
    json.dump(msg, f)
" <<< "$MESSAGE"

    echo "$msg_id"
}

# --- Actions ---

case "$ACTION" in
    start-session)
        if [[ "$(is_session_active)" == "true" ]]; then
            echo '{"status":"error","message":"Session already active"}' >&2
            exit 1
        fi
        SESSION_ID=$(gen_uuid)
        cat > "$SESSION_FILE" <<SSEOF
{
    "session_id": "$SESSION_ID",
    "active": true,
    "created_at": "$(iso_timestamp)",
    "ended_at": null,
    "system_prompt": "AI group chat session",
    "current_seq": 0,
    "participants": []
}
SSEOF
        echo "{\"status\":\"ok\",\"session_id\":\"$SESSION_ID\"}"
        ;;

    join)
        [[ -z "$AGENT" ]] && { echo '{"status":"error","message":"--agent required"}' >&2; exit 1; }
        if [[ "$(is_session_active)" != "true" ]]; then
            echo '{"status":"error","message":"No active session"}' >&2
            exit 1
        fi
        session_id=$(get_session_id)
        # Reset last_seen_seq if joining a different session (prevents stale high values)
        old_session=$(python3 -c "import json; d=json.load(open('$PARTICIPANTS/${AGENT}.json')); print(d.get('session_id',''))" 2>/dev/null || echo "")
        if [[ "$old_session" != "$session_id" ]]; then
            last_seen=0
        else
            last_seen=$(get_last_seen_seq)
        fi
        update_participant "true" "idle" "$session_id" "$last_seen"
        mkdir -p "$INBOX/$AGENT"
        echo "{\"status\":\"ok\",\"agent\":\"$AGENT\",\"session_id\":\"$session_id\"}"
        ;;

    leave)
        [[ -z "$AGENT" ]] && { echo '{"status":"error","message":"--agent required"}' >&2; exit 1; }
        update_participant "false" "silent" "" "0"
        rm -f "$INBOX/$AGENT/ping"
        echo "{\"status\":\"ok\",\"agent\":\"$AGENT\"}"
        ;;

    send)
        [[ -z "$AGENT" ]] && { echo '{"status":"error","message":"--agent required"}' >&2; exit 1; }
        [[ -z "$MESSAGE" ]] && { echo '{"status":"error","message":"No message"}' >&2; exit 1; }
        if [[ "$(is_session_active)" != "true" ]]; then
            echo '{"status":"error","message":"No active session"}' >&2
            exit 1
        fi
        # Update heartbeat
        session_id=$(get_session_id)
        last_seen=$(get_last_seen_seq)
        update_participant "true" "sending" "$session_id" "$last_seen"

        msg_id=$(write_staging_safe)
        echo "{\"status\":\"ok\",\"msg_id\":\"$msg_id\"}"

        # Back to idle
        sleep 0.5
        update_participant "true" "idle" "$session_id" "$last_seen"
        ;;

    poll)
        [[ -z "$AGENT" ]] && { echo '{"status":"error","message":"--agent required"}' >&2; exit 1; }

        last_seen=$(get_last_seen_seq)
        if [[ $SINCE_SEQ -gt 0 ]]; then
            last_seen=$SINCE_SEQ
        fi

        if [[ ! -f "$CHAT_LOG" ]]; then
            # No messages yet
            exit 0
        fi

        # Read new messages and output as NDJSON
        max_seq=$last_seen
        while IFS= read -r line; do
            seq=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('seq',0))" 2>/dev/null || echo "0")
            if [[ "$seq" -gt "$last_seen" ]]; then
                echo "$line"
                if [[ "$seq" -gt "$max_seq" ]]; then
                    max_seq=$seq
                fi
            fi
        done < "$CHAT_LOG"

        # Update last_seen_seq
        if [[ "$max_seq" -gt "$last_seen" ]]; then
            session_id=$(get_session_id)
            update_participant "true" "idle" "$session_id" "$max_seq"
        fi

        # Clear ping
        rm -f "$INBOX/$AGENT/ping"
        ;;

    listen)
        [[ -z "$AGENT" ]] && { echo '{"status":"error","message":"--agent required"}' >&2; exit 1; }
        if ! command -v fswatch &>/dev/null; then
            echo '{"status":"error","message":"fswatch not installed. Run: brew install fswatch"}' >&2
            exit 1
        fi

        last_seen=$(get_last_seen_seq)
        if [[ $SINCE_SEQ -gt 0 ]]; then
            last_seen=$SINCE_SEQ
        fi

        ping_file="$INBOX/$AGENT/ping"
        mkdir -p "$(dirname "$ping_file")"

        # Dump any existing new messages first
        if [[ -f "$CHAT_LOG" ]]; then
            while IFS= read -r line; do
                seq=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('seq',0))" 2>/dev/null || echo "0")
                if [[ "$seq" -gt "$last_seen" ]]; then
                    echo "$line"
                    last_seen=$seq
                fi
            done < "$CHAT_LOG"
        fi

        # Event-driven loop: block on fswatch, read on wake
        while true; do
            # If ping already exists, process immediately (skip fswatch — avoids race condition
            # where ping was created between message dump and fswatch start)
            if [[ ! -f "$ping_file" ]]; then
                # Block until ping file is touched (zero CPU while waiting)
                fswatch -1 --event Created --event Updated --event Renamed "$INBOX/$AGENT/" >/dev/null 2>&1
            fi
            rm -f "$ping_file"

            # Read new messages
            if [[ -f "$CHAT_LOG" ]]; then
                while IFS= read -r line; do
                    seq=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('seq',0))" 2>/dev/null || echo "0")
                    if [[ "$seq" -gt "$last_seen" ]]; then
                        echo "$line"
                        last_seen=$seq
                    fi
                done < "$CHAT_LOG"
            fi

            # Update heartbeat
            session_id=$(get_session_id)
            update_participant "true" "idle" "$session_id" "$last_seen"
        done
        ;;

    follow)
        [[ -z "$AGENT" ]] && { echo '{"status":"error","message":"--agent required"}' >&2; exit 1; }

        last_seen=$(get_last_seen_seq)
        if [[ $SINCE_SEQ -gt 0 ]]; then
            last_seen=$SINCE_SEQ
        fi

        # First dump any existing new messages
        if [[ -f "$CHAT_LOG" ]]; then
            while IFS= read -r line; do
                seq=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('seq',0))" 2>/dev/null || echo "0")
                if [[ "$seq" -gt "$last_seen" ]]; then
                    echo "$line"
                    last_seen=$seq
                fi
            done < "$CHAT_LOG"
        fi

        # Then tail for new messages
        while true; do
            # Wait for ping or timeout
            ping_file="$INBOX/$AGENT/ping"
            waited=0
            while [[ ! -f "$ping_file" ]] && [[ $waited -lt 20 ]]; do
                sleep 2
                waited=$((waited + 2))
            done
            rm -f "$ping_file"

            # Read new messages
            if [[ -f "$CHAT_LOG" ]]; then
                while IFS= read -r line; do
                    seq=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('seq',0))" 2>/dev/null || echo "0")
                    if [[ "$seq" -gt "$last_seen" ]]; then
                        echo "$line"
                        last_seen=$seq
                    fi
                done < "$CHAT_LOG"
            fi

            # Update heartbeat
            session_id=$(get_session_id)
            update_participant "true" "idle" "$session_id" "$last_seen"
        done
        ;;

    status)
        [[ -z "$AGENT" ]] && { echo '{"status":"error","message":"--agent required"}' >&2; exit 1; }
        session_id=$(get_session_id)
        last_seen=$(get_last_seen_seq)
        update_participant "true" "$STATUS_MODE" "$session_id" "$last_seen"
        echo "{\"status\":\"ok\",\"mode\":\"$STATUS_MODE\"}"
        ;;

    who)
        echo "["
        first=true
        for pfile in "$PARTICIPANTS"/*.json; do
            [[ -f "$pfile" ]] || continue
            if $first; then first=false; else echo ","; fi
            cat "$pfile"
        done
        echo "]"
        ;;

    session-info)
        if [[ -f "$SESSION_FILE" ]]; then
            cat "$SESSION_FILE"
        else
            echo '{"status":"error","message":"No session file"}'
        fi
        ;;

    *)
        echo '{"status":"error","message":"No action specified. Use --help"}' >&2
        exit 1
        ;;
esac
