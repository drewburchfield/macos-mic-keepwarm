#!/bin/bash
# Unit regressions run without microphone access. Integration tests below require
# a working microphone and no other native mic-warm instance running.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
./test-instance-lock.sh
swift build

BINARY="$SCRIPT_DIR/.build/debug/mic-warm"
if [ -f "$SCRIPT_DIR/.build/apple/Products/Release/mic-warm" ]; then
    BINARY="$SCRIPT_DIR/.build/apple/Products/Release/mic-warm"
fi
TEST_DIR=$(mktemp -d)
TEST_PID=""
DUPLICATE_PID=""

cleanup() {
    if [ -n "$DUPLICATE_PID" ]; then
        kill "$DUPLICATE_PID" 2>/dev/null || true
        wait "$DUPLICATE_PID" 2>/dev/null || true
    fi
    if [ -n "$TEST_PID" ]; then
        kill "$TEST_PID" 2>/dev/null || true
        wait "$TEST_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

wait_for_log() {
    local pattern="$1" file="$2"
    for ((i=0; i<40; i++)); do
        if grep -q "$pattern" "$file" 2>/dev/null; then return 0; fi
        sleep 0.25
    done
    cat "$file"
    echo "Missing log: $pattern" >&2
    return 1
}

start_binary() {
    "$BINARY" > "$TEST_DIR/output.log" 2>&1 &
    TEST_PID=$!
    wait_for_log 'Keeping warm: .*isRunning=true' "$TEST_DIR/output.log"
    kill -0 "$TEST_PID"
}

stop_binary() {
    kill "-$1" "$TEST_PID"
    wait "$TEST_PID"
    TEST_PID=""
}

start_binary
sleep 1
kill -0 "$TEST_PID"
echo 'PASS: starts capture and stays alive'

"$BINARY" > "$TEST_DIR/duplicate.log" 2>&1 &
DUPLICATE_PID=$!
wait_for_log 'already running; exiting without stopping it' "$TEST_DIR/duplicate.log"
wait "$DUPLICATE_PID"
DUPLICATE_PID=""
kill -0 "$TEST_PID"
echo 'PASS: duplicate exits without terminating the first instance'

stop_binary TERM
start_binary
echo 'PASS: SIGTERM exits cleanly and releases the lock'
stop_binary INT
start_binary
echo 'PASS: SIGINT exits cleanly and releases the lock'
stop_binary KILL || true
TEST_PID=""
start_binary
echo 'PASS: SIGKILL releases the lock without cleanup code'
stop_binary TERM
