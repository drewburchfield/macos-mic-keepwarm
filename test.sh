#!/bin/bash
# test.sh - Integration tests for mic-warm binary.
# Tests process lifecycle, PID file management, signal handling, and logging.
# Device-switching tests require real hardware and stay manual.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY=""
TEST_PID=""
PASS=0
FAIL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Build ────────────────────────────────────────────────────────

build_if_needed() {
    local debug_bin="$SCRIPT_DIR/.build/debug/mic-warm"
    local release_bin="$SCRIPT_DIR/.build/apple/Products/Release/mic-warm"

    # Prefer existing release binary (CI), fall back to debug build
    if [ -f "$release_bin" ]; then
        BINARY="$release_bin"
        return
    fi

    if [ ! -f "$debug_bin" ] || [ "$SCRIPT_DIR/Sources/MicWarm/main.swift" -nt "$debug_bin" ]; then
        echo "Building mic-warm..."
        (cd "$SCRIPT_DIR" && swift build 2>&1) || {
            echo -e "${RED}Build failed${RESET}"
            exit 1
        }
    fi
    BINARY="$debug_bin"
}

# ── Setup / Teardown ────────────────────────────────────────────

TEST_DIR=""

setup() {
    TEST_DIR=$(mktemp -d)
}

teardown() {
    if [ -n "$TEST_PID" ] && kill -0 "$TEST_PID" 2>/dev/null; then
        kill "$TEST_PID" 2>/dev/null || true
        wait "$TEST_PID" 2>/dev/null || true
    fi
    TEST_PID=""

    # Clean up PID file if tests used the default path
    rm -f /tmp/mic-warm.pid

    if [ -n "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
    TEST_DIR=""
}

# ── Helpers ─────────────────────────────────────────────────────

start_binary() {
    "$BINARY" > "$TEST_DIR/output.log" 2>&1 &
    TEST_PID=$!
}

wait_for_log() {
    local pattern="$1"
    local ticks="${2:-20}"
    local i=0
    while [ "$i" -lt "$ticks" ]; do
        if grep -q "$pattern" "$TEST_DIR/output.log" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

assert_log() {
    local pattern="$1"
    local msg="${2:-Expected log pattern: $pattern}"
    if grep -q "$pattern" "$TEST_DIR/output.log" 2>/dev/null; then
        return 0
    else
        echo ""
        echo "  ASSERT FAILED: $msg"
        echo "  Pattern: $pattern"
        echo "  Log contents:"
        sed 's/^/    /' "$TEST_DIR/output.log" 2>/dev/null || echo "    (empty)"
        return 1
    fi
}

run_test() {
    local name="$1"
    local func="$2"
    echo -n "  $name ... "
    setup
    if $func; then
        echo -e "${GREEN}PASS${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${RESET}"
        FAIL=$((FAIL + 1))
    fi
    teardown
}

# ── Test Cases ──────────────────────────────────────────────────

test_binary_starts_and_stays_alive() {
    start_binary
    wait_for_log "Keeping warm:" || return 1

    # Verify still running after 2 seconds
    sleep 2
    kill -0 "$TEST_PID" 2>/dev/null || { echo "  Binary died"; return 1; }
}

test_pid_file_created() {
    start_binary
    wait_for_log "Keeping warm:" || return 1

    [ -f /tmp/mic-warm.pid ] || { echo "  PID file not created"; return 1; }
    local file_pid
    file_pid=$(cat /tmp/mic-warm.pid)
    [ "$file_pid" = "$TEST_PID" ] || { echo "  PID mismatch: file=$file_pid actual=$TEST_PID"; return 1; }
}

test_clean_shutdown_sigterm() {
    start_binary
    wait_for_log "Keeping warm:" || return 1

    kill -TERM "$TEST_PID"
    wait "$TEST_PID" 2>/dev/null || true

    # Signal handler uses _exit(0) without logging (signal-safe),
    # so we verify clean shutdown by checking the PID file was removed.
    [ ! -f /tmp/mic-warm.pid ] || { echo "  PID file not cleaned up"; return 1; }
}

test_clean_shutdown_sigint() {
    start_binary
    wait_for_log "Keeping warm:" || return 1

    kill -INT "$TEST_PID"
    wait "$TEST_PID" 2>/dev/null || true

    [ ! -f /tmp/mic-warm.pid ] || { echo "  PID file not cleaned up"; return 1; }
}

test_logs_device_name() {
    start_binary
    wait_for_log "Keeping warm:" || return 1

    # The log should contain a device name (not empty)
    local line
    line=$(grep "Keeping warm:" "$TEST_DIR/output.log" 2>/dev/null)
    [ -n "$line" ] || { echo "  No 'Keeping warm' line found"; return 1; }

    # Device name should be non-empty after the colon
    local device_name
    device_name=$(echo "$line" | sed 's/.*Keeping warm: //')
    [ -n "$device_name" ] || { echo "  Device name is empty"; return 1; }
}

test_stale_pid_cleanup() {
    # Write a PID file pointing to a dead process
    echo "99999" > /tmp/mic-warm.pid

    start_binary
    wait_for_log "Keeping warm:" || return 1

    # PID file should now contain our process PID
    local file_pid
    file_pid=$(cat /tmp/mic-warm.pid)
    [ "$file_pid" = "$TEST_PID" ] || { echo "  PID not updated: $file_pid"; return 1; }
}

test_stale_pid_cleanup_live_process() {
    # Start a real process and use its PID as the "stale" one
    sleep 300 &
    disown
    local stale_pid=$!
    echo "$stale_pid" > /tmp/mic-warm.pid

    start_binary
    wait_for_log "Killing stale process" || return 1
    wait_for_log "Keeping warm:" || return 1

    # The stale process should have been killed
    if kill -0 "$stale_pid" 2>/dev/null; then
        kill "$stale_pid" 2>/dev/null || true
        echo "  Stale process was not killed"
        return 1
    fi
}

# ── Runner ──────────────────────────────────────────────────────

build_if_needed

echo ""
echo -e "${BOLD}mic-warm integration tests${RESET}"
echo "─────────────────────────────────────────────"

run_test "Binary starts and stays alive"         test_binary_starts_and_stays_alive
run_test "PID file created with correct PID"     test_pid_file_created
run_test "Clean shutdown on SIGTERM"              test_clean_shutdown_sigterm
run_test "Clean shutdown on SIGINT"               test_clean_shutdown_sigint
run_test "Logs device name on startup"            test_logs_device_name
run_test "Stale PID cleanup (dead process)"       test_stale_pid_cleanup
run_test "Stale PID cleanup (live process)"       test_stale_pid_cleanup_live_process

echo "─────────────────────────────────────────────"
echo -e "Results: ${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
