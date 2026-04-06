#!/bin/bash
# buck-exec.sh — Agent loop giving ChatGPT local terminal access via Buck
#
# Usage:
#   buck-exec.sh task.md                          # Task from file
#   buck-exec.sh --text "list all Swift files"    # Inline task
#   buck-exec.sh --stdin <<'EOF'                  # Task from stdin
#   Fix the bug in main.swift
#   EOF
#   buck-exec.sh --workdir ~/project --auto task.md  # Autonomous mode

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUCK_REVIEW="$SCRIPT_DIR/buck-review.sh"
PROMPT_FILE="$SCRIPT_DIR/prompts/exec-system.txt"

# ─── Defaults ───────────────────────────────────────────────────────
WORKDIR="$PWD"
MAX_TURNS=20
CMD_TIMEOUT=30
AUTO=false
CHANNEL="${BUCK_CHANNEL:-}"
CALLER="${BUCK_CALLER:-}"
CONTENT=""

# ─── Parse args ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stdin)      CONTENT=$(cat); shift ;;
        --text)       CONTENT="$2"; shift 2 ;;
        --workdir)    WORKDIR="$2"; shift 2 ;;
        --max-turns)  MAX_TURNS="$2"; shift 2 ;;
        --timeout)    CMD_TIMEOUT="$2"; shift 2 ;;
        --auto)       AUTO=true; shift ;;
        --channel)    CHANNEL="$2"; shift 2 ;;
        --caller)     CALLER="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: buck-exec.sh [options] [task_file]"
            echo ""
            echo "Options:"
            echo "  --text TEXT       Inline task description"
            echo "  --stdin           Read task from stdin"
            echo "  --workdir PATH    Working directory (default: \$PWD)"
            echo "  --max-turns N     Max agent loop iterations (default: 20)"
            echo "  --timeout N       Per-command timeout in seconds (default: 30)"
            echo "  --auto            Skip interactive confirmation"
            echo "  --channel X       Buck channel (default: \$BUCK_CHANNEL)"
            echo "  --caller NAME     Caller identifier (default: \$BUCK_CALLER)"
            exit 0
            ;;
        *)
            if [[ -f "$1" ]]; then CONTENT=$(cat "$1")
            else echo "Error: File not found: $1" >&2; exit 1; fi
            shift ;;
    esac
done

if [[ -z "$CONTENT" ]]; then
    echo "Usage: buck-exec.sh [--text \"task\"] [--stdin] [task_file]" >&2
    echo "Run buck-exec.sh --help for options." >&2
    exit 1
fi

# ─── Validate ───────────────────────────────────────────────────────
WORKDIR=$(cd "$WORKDIR" && pwd)

if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: Prompt template not found: $PROMPT_FILE" >&2
    exit 1
fi

if [[ ! -f "$BUCK_REVIEW" ]]; then
    echo "Error: buck-review.sh not found: $BUCK_REVIEW" >&2
    exit 1
fi

SYSTEM_PROMPT=$(sed "s|{WORKDIR}|$WORKDIR|g" "$PROMPT_FILE")

# ─── Helpers ────────────────────────────────────────────────────────

# Send a message to ChatGPT via buck-review.sh and return the response text.
send_to_gpt() {
    local prompt="$1"
    local content="$2"
    local flags=()
    [[ -n "$CHANNEL" ]] && flags+=(--channel "$CHANNEL")
    [[ -n "$CALLER" ]]  && flags+=(--caller "$CALLER")

    local json
    json=$("$BUCK_REVIEW" --prompt "$prompt" ${flags[@]+"${flags[@]}"} --stdin <<< "$content") || {
        echo "Error: buck-review.sh failed" >&2
        return 1
    }

    python3 -c "import json,sys; print(json.load(sys.stdin).get('response',''))" <<< "$json"
}

# Parse ChatGPT's response text for <tool> or <done> tags.
# Returns JSON: {type, name, path, body, reasoning, done_content}
parse_response() {
    python3 <<'PYEOF'
import re, json, sys

response = sys.stdin.read()
result = {
    "type": "none",
    "name": "",
    "path": "",
    "body": "",
    "reasoning": response.strip(),
    "done_content": ""
}

# Check for <done>
m = re.search(r"<done>(.*?)</done>", response, re.DOTALL)
if m:
    result["type"] = "done"
    result["done_content"] = m.group(1).strip()
    result["reasoning"] = response[:m.start()].strip()
    print(json.dumps(result))
    sys.exit(0)

# Check for <tool>
m = re.search(r"<tool\s+([^>]*)>(.*?)</tool>", response, re.DOTALL)
if m:
    attrs = m.group(1)
    nm = re.search(r'name="([\w_]+)"', attrs)
    pm = re.search(r'path="([^"]*)"', attrs)
    result["type"] = "tool"
    result["name"] = nm.group(1) if nm else "bash"
    result["path"] = pm.group(1) if pm else ""
    result["body"] = m.group(2).strip("\n")
    result["reasoning"] = response[:m.start()].strip()
    print(json.dumps(result))
    sys.exit(0)

print(json.dumps(result))
PYEOF
}

# Extract a field from a JSON string.
jf() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])" <<< "$2"; }

# Run a command with a timeout (macOS-compatible, no GNU timeout needed).
run_with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill -TERM "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local code=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return $code
}

# Execute a tool command and print its output. Returns the command's exit code.
run_tool() {
    local name="$1" body="$2" path="$3"
    local tmpscript tmpout exit_code=0
    tmpscript=$(mktemp)
    tmpout=$(mktemp)

    case "$name" in
        bash)
            printf '%s\n' "$body" > "$tmpscript"
            run_with_timeout "$CMD_TIMEOUT" bash -c "cd \"$WORKDIR\" && bash \"$tmpscript\"" > "$tmpout" 2>&1 || exit_code=$?
            ;;
        read_file)
            local fp="$body"
            [[ "$fp" != /* ]] && fp="$WORKDIR/$fp"
            cat -n "$fp" > "$tmpout" 2>&1 || exit_code=$?
            ;;
        write_file)
            local fp="$path"
            [[ "$fp" != /* ]] && fp="$WORKDIR/$fp"
            mkdir -p "$(dirname "$fp")" 2>/dev/null
            if printf '%s\n' "$body" > "$fp" 2>"$tmpout"; then
                echo "Written: $fp" > "$tmpout"
            else
                exit_code=$?
                echo "Failed to write: $fp" >> "$tmpout"
            fi
            ;;
        list_files)
            find "$WORKDIR" -name "$body" -type f 2>/dev/null | head -200 > "$tmpout" || exit_code=$?
            ;;
        search)
            local sp="${path:-$WORKDIR}"
            [[ "$sp" != /* ]] && sp="$WORKDIR/$sp"
            grep -rn "$body" "$sp" 2>/dev/null | head -200 > "$tmpout" || exit_code=$?
            ;;
        *)
            echo "Unknown tool: $name" > "$tmpout"
            exit_code=1
            ;;
    esac

    # Truncate long output (keep first 100 + last 100 lines)
    local lines
    lines=$(wc -l < "$tmpout" | tr -d ' ')
    if [[ $lines -gt 200 ]]; then
        local tmp2; tmp2=$(mktemp)
        { head -100 "$tmpout"
          echo "... [truncated: $lines total lines — showing first 100 + last 100] ..."
          tail -100 "$tmpout"
        } > "$tmp2"
        mv "$tmp2" "$tmpout"
    fi

    cat "$tmpout"
    rm -f "$tmpscript" "$tmpout"
    return $exit_code
}

# ─── Main agent loop ───────────────────────────────────────────────
echo "" >&2
echo "BuckExec — ChatGPT Agent Session" >&2
echo "  Workdir:     $WORKDIR" >&2
echo "  Max turns:   $MAX_TURNS" >&2
echo "  Cmd timeout: ${CMD_TIMEOUT}s" >&2
echo "  Mode:        $($AUTO && echo 'autonomous' || echo 'interactive')" >&2
echo "" >&2

# First turn: send system prompt + task
turn=0
echo "── Sending task to ChatGPT ──" >&2
response=$(send_to_gpt "$SYSTEM_PROMPT" "$CONTENT") || { echo "Failed to send initial task." >&2; exit 1; }

while [[ $turn -lt $MAX_TURNS ]]; do
    turn=$((turn + 1))

    parsed=$(parse_response <<< "$response")
    action=$(jf type "$parsed")

    # ── Done ──
    if [[ "$action" == "done" ]]; then
        reasoning=$(jf reasoning "$parsed")
        [[ -n "$reasoning" ]] && { echo "" >&2; echo "$reasoning" >&2; }
        echo "" >&2
        echo "══ Task Complete (turn $turn) ══" >&2
        jf done_content "$parsed"
        exit 0
    fi

    # ── No tool call ──
    if [[ "$action" == "none" ]]; then
        echo "" >&2
        echo "ChatGPT responded without a tool call:" >&2
        echo "$response"
        exit 0
    fi

    # ── Tool call ──
    tool_name=$(jf name "$parsed")
    tool_path=$(jf path "$parsed")
    tool_body=$(jf body "$parsed")
    reasoning=$(jf reasoning "$parsed")

    [[ -n "$reasoning" ]] && { echo "" >&2; echo "$reasoning" >&2; }

    # Display command
    echo "" >&2
    echo "╭─ Turn $turn: $tool_name ──────────────────────────" >&2
    if [[ "$tool_name" == "write_file" ]]; then
        local_lines=$(printf '%s' "$tool_body" | wc -l | tr -d ' ')
        echo "│ Path: $tool_path" >&2
        echo "│ Content: $local_lines lines" >&2
    else
        # Show command (indent multi-line)
        while IFS= read -r line; do
            echo "│ $line" >&2
        done <<< "$tool_body"
    fi
    echo "╰───────────────────────────────────────────────────" >&2

    # Interactive confirmation
    if ! $AUTO; then
        read -rp "Execute? [Y/n/skip] " confirm </dev/tty
        case "${confirm,,}" in
            n|no)
                echo "Aborted." >&2
                exit 1
                ;;
            s|skip)
                result_text="<result name=\"$tool_name\" exit_code=\"-1\">Skipped by user</result>"
                echo "  Skipped" >&2
                echo "" >&2
                echo "── Sending skip result to ChatGPT ──" >&2
                response=$(send_to_gpt "" "$result_text") || { echo "Failed to send result." >&2; exit 1; }
                continue
                ;;
        esac
    fi

    # Execute
    echo "  Running..." >&2
    tool_output=""
    tool_exit=0
    tool_output=$(run_tool "$tool_name" "$tool_body" "$tool_path") || tool_exit=$?
    echo "  Exit code: $tool_exit" >&2

    # Show brief output preview
    local_lines=$(echo "$tool_output" | wc -l | tr -d ' ')
    if [[ $local_lines -le 5 ]]; then
        echo "$tool_output" >&2
    else
        echo "  ($local_lines lines of output)" >&2
    fi

    # Format result and send back
    result_text="<result name=\"$tool_name\" exit_code=\"$tool_exit\">
$tool_output
</result>"

    echo "" >&2
    echo "── Sending result to ChatGPT ──" >&2
    response=$(send_to_gpt "" "$result_text") || { echo "Failed to send result." >&2; exit 1; }
done

echo "" >&2
echo "Error: Max turns ($MAX_TURNS) reached." >&2
echo "Last ChatGPT response:" >&2
echo "$response"
exit 1
