#!/bin/bash
# test.sh - Integration tests for mic-warm binary.
# Tests process lifecycle, the single-instance lock, signal handling, and logging.
# Each test uses its own lock file (MIC_WARM_LOCK), so a running mic-warm daemon is left alone.
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
    local release_bin
    # Prefer a current release binary (CI's universal build), fall back to a debug build.
    for release_bin in "$SCRIPT_DIR/.build/apple/Products/Release/mic-warm" \
                       "$SCRIPT_DIR/.build/out/Products/Release/mic-warm"; do
        if [ -f "$release_bin" ] && [ ! "$SCRIPT_DIR/Sources/MicWarm/main.swift" -nt "$release_bin" ]; then
            BINARY="$release_bin"
            return
        fi
    done

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
LOCK=""
EXTRA_PIDS=()

setup() {
    TEST_DIR=$(mktemp -d)
    LOCK="$TEST_DIR/mic-warm.lock"
    EXTRA_PIDS=()
}

teardown() {
    if [ -n "$TEST_PID" ] && kill -0 "$TEST_PID" 2>/dev/null; then
        kill "$TEST_PID" 2>/dev/null || true
        wait "$TEST_PID" 2>/dev/null || true
    fi
    TEST_PID=""
    for pid in ${EXTRA_PIDS[@]+"${EXTRA_PIDS[@]}"}; do
        kill "$pid" 2>/dev/null || true
    done

    if [ -n "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
    TEST_DIR=""
}

# ── Helpers ─────────────────────────────────────────────────────

start_binary() {
    MIC_WARM_LOCK="$LOCK" "$BINARY" > "$TEST_DIR/output.log" 2>&1 &
    TEST_PID=$!
}

# Exit 0 if nobody holds the lock (lockf uses flock; -k keeps the file).
lock_is_free() {
    lockf -k -t 0 "$LOCK" true 2>/dev/null
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

test_lock_records_pid() {
    start_binary
    wait_for_log "Keeping warm:" || return 1

    [ -f "$LOCK" ] || { echo "  Lock file not created"; return 1; }
    local file_pid
    file_pid=$(tr -d '[:space:]' < "$LOCK")
    [ "$file_pid" = "$TEST_PID" ] || { echo "  PID mismatch: file=$file_pid actual=$TEST_PID"; return 1; }
    lock_is_free && { echo "  Lock is not held"; return 1; }
    return 0
}

test_clean_shutdown_sigterm() {
    start_binary
    wait_for_log "Keeping warm:" || return 1

    kill -TERM "$TEST_PID"
    wait "$TEST_PID" 2>/dev/null || true

    # The signal handler exits without logging (signal-safe); the kernel drops the lock.
    lock_is_free || { echo "  Lock still held after SIGTERM"; return 1; }
}

test_clean_shutdown_sigint() {
    start_binary
    wait_for_log "Keeping warm:" || return 1

    kill -INT "$TEST_PID"
    wait "$TEST_PID" 2>/dev/null || true

    lock_is_free || { echo "  Lock still held after SIGINT"; return 1; }
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

test_stale_pid_never_signalled() {
    # An unlocked lock file naming a live, unrelated process (a leftover, or PID reuse).
    sleep 300 &
    local bystander=$!
    disown
    EXTRA_PIDS+=("$bystander")
    echo "$bystander" > "$LOCK"

    start_binary
    wait_for_log "Keeping warm:" || return 1

    kill -0 "$bystander" 2>/dev/null || { echo "  Unrelated process was killed"; return 1; }
    grep -q "Replacing running instance" "$TEST_DIR/output.log" && { echo "  Signalled a process it did not prove was mic-warm"; return 1; }
    [ "$(tr -d '[:space:]' < "$LOCK")" = "$TEST_PID" ] || { echo "  Lock PID not updated"; return 1; }
    return 0
}

test_new_instance_replaces_running_one() {
    MIC_WARM_LOCK="$LOCK" "$BINARY" > "$TEST_DIR/first.log" 2>&1 &
    local first=$!
    disown
    EXTRA_PIDS+=("$first")
    local i=0
    until grep -q "Keeping warm:" "$TEST_DIR/first.log" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -lt 20 ] || { echo "  First instance never started"; return 1; }
        sleep 0.5
    done

    start_binary
    wait_for_log "Replacing running instance (PID: $first)" || return 1
    wait_for_log "Keeping warm:" || return 1
    sleep 1
    kill -0 "$first" 2>/dev/null && { echo "  First instance still running"; return 1; }
    return 0
}

test_foreign_lock_holder_is_not_killed() {
    # Something that is not mic-warm holds the lock: wait, then give up without signalling it.
    lockf -k "$LOCK" sleep 30 &
    local holder=$!
    disown
    EXTRA_PIDS+=("$holder")
    sleep 0.5

    start_binary
    wait_for_log "not mic-warm" || return 1
    wait "$TEST_PID" 2>/dev/null && { echo "  Expected a nonzero exit"; return 1; }
    TEST_PID=""
    kill -0 "$holder" 2>/dev/null || { echo "  Lock holder was killed"; return 1; }
    return 0
}

# ── Runner ──────────────────────────────────────────────────────

build_if_needed

echo ""
echo -e "${BOLD}mic-warm integration tests${RESET}"
echo "─────────────────────────────────────────────"

run_test "Binary starts and stays alive"         test_binary_starts_and_stays_alive
run_test "Lock held and records the PID"         test_lock_records_pid
run_test "Clean shutdown on SIGTERM"              test_clean_shutdown_sigterm
run_test "Clean shutdown on SIGINT"               test_clean_shutdown_sigint
run_test "Logs device name on startup"            test_logs_device_name
run_test "Stale PID in lock file never signalled" test_stale_pid_never_signalled
run_test "New instance replaces a running one"    test_new_instance_replaces_running_one
run_test "Foreign lock holder is not killed"      test_foreign_lock_holder_is_not_killed

echo "─────────────────────────────────────────────"
echo -e "Results: ${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
