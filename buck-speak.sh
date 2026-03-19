#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="/Applications/BuckSpeak.app"
BUCKSPEAK_ROOT="${HOME}/.buckspeak"
INBOX_DIR="${BUCKSPEAK_ROOT}/inbox"
OUTBOX_DIR="${BUCKSPEAK_ROOT}/outbox"

emit_wrapper_error() {
    local code="$1"
    printf '%s\n' "{\"status\":\"error\",\"mode\":\"wrapper\",\"spoken_text\":null,\"heard_text\":null,\"speech_started_ms\":null,\"speech_ended_ms\":null,\"duration_ms\":0,\"error\":\"${code}\"}"
}

usage() {
    cat <<'EOF'
Usage:
  buck-speak.sh --speak --text "Hey ARIA"
  buck-speak.sh --listen
  buck-speak.sh --speak-listen --text "Hey ARIA"

Options:
  --text TEXT             Text to speak
  --stdin                 Read text to speak from stdin
  --voice NAME            Optional macOS say voice name
  --rate WPM              Optional macOS say rate
  --listen-timeout MS     Listen timeout in milliseconds
  --silence-timeout MS    Silence timeout in milliseconds
  --locale ID             Optional speech recognizer locale
  --help                  Show this help
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ ! -d "$APP_PATH" ]]; then
    emit_wrapper_error "buckspeak_app_not_found"
    exit 1
fi

mkdir -p "$INBOX_DIR" "$OUTBOX_DIR"
open -ga "$APP_PATH"

request_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
request_path="${INBOX_DIR}/${request_id}.json"
response_path="${OUTBOX_DIR}/${request_id}.json"
stdin_tmp=""

cleanup() {
    if [[ -n "$stdin_tmp" && -f "$stdin_tmp" ]]; then
        rm -f "$stdin_tmp"
    fi
}
trap cleanup EXIT

for arg in "$@"; do
    if [[ "$arg" == "--stdin" ]]; then
        stdin_tmp="$(mktemp)"
        cat > "$stdin_tmp"
        break
    fi
done

REQUEST_ID="$request_id" REQUEST_PATH="$request_path" STDIN_FILE="$stdin_tmp" /usr/bin/python3 - "$@" <<'PY'
import json
import os
import sys

stdin_text = None
stdin_file = os.environ.get("STDIN_FILE") or ""
if stdin_file:
    with open(stdin_file, "r", encoding="utf-8") as f:
        stdin_text = f.read()

payload = {
    "id": os.environ["REQUEST_ID"],
    "arguments": sys.argv[1:],
    "stdinText": stdin_text,
}

with open(os.environ["REQUEST_PATH"], "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
PY

listen_timeout_ms=20000
mode=""
for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    case "$arg" in
        --listen)
            mode="listen"
            ;;
        --speak-listen)
            mode="speak-listen"
            ;;
        --listen-timeout)
            next_index=$((i + 1))
            if (( next_index <= $# )); then
                listen_timeout_ms="${!next_index}"
            fi
            ;;
    esac
done

wrapper_timeout_ms=30000
case "$mode" in
    listen)
        wrapper_timeout_ms=$((listen_timeout_ms + 5000))
        ;;
    speak-listen)
        wrapper_timeout_ms=$((listen_timeout_ms + 15000))
        ;;
esac

deadline=$((SECONDS + ((wrapper_timeout_ms + 999) / 1000)))
while [[ ! -f "$response_path" ]]; do
    if (( SECONDS >= deadline )); then
        emit_wrapper_error "timeout_waiting_for_response"
        rm -f "$request_path"
        exit 1
    fi
    sleep 0.1
done

cat "$response_path"
status="$(/usr/bin/python3 - "$response_path" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f).get("status", "error"))
PY
)"
rm -f "$response_path"

if [[ "$status" == "error" ]]; then
    exit 1
fi

exit 0
