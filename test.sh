#!/bin/bash
# test.sh - Test suite for keep-mic-warm.sh
# Uses mock binaries to simulate audio device failures and recovery.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR=""
SCRIPT_PID=""
PASS=0
FAIL=0
POLL=0.5  # patched poll interval for faster tests

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

# Isolated PATH: mocks + basic system utils, but NOT brew (where real
# ffmpeg/SwitchAudioSource live). This lets "missing" tests actually fail.
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ── Setup / Teardown ─────────────────────────────────────────────

setup() {
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/logs"

    # Control file for mock SwitchAudioSource
    echo "MacBook Pro Microphone" > "$TEST_DIR/device"

    # Mock SwitchAudioSource: returns contents of control file
    cat > "$TEST_DIR/bin/SwitchAudioSource" << MOCK
#!/bin/bash
CONTROL_FILE="$TEST_DIR/device"
if [ -f "\$CONTROL_FILE" ]; then
    cat "\$CONTROL_FILE"
else
    echo ""
    exit 1
fi
MOCK
    chmod +x "$TEST_DIR/bin/SwitchAudioSource"

    # Mock ffmpeg: sleeps until killed, or exits immediately if fail flag exists
    cat > "$TEST_DIR/bin/ffmpeg" << MOCK
#!/bin/bash
if [ -f "$TEST_DIR/ffmpeg_fail" ]; then
    exit 1
fi
while true; do sleep 60; done
MOCK
    chmod +x "$TEST_DIR/bin/ffmpeg"

    # Patched script: shorter poll interval, isolated PID path, shorter
    # coreaudiod recovery sleep (0.5s instead of 2s)
    sed \
        -e "s|POLL_INTERVAL=2|POLL_INTERVAL=$POLL|" \
        -e "s|DEBOUNCE_WAIT=3|DEBOUNCE_WAIT=1|" \
        -e "s|DEBOUNCE_CHECKS=3|DEBOUNCE_CHECKS=2|" \
        -e "s|/tmp/mic-warm.pid|$TEST_DIR/mic-warm.pid|g" \
        -e '/Wait for audio subsystem/,/^fi$/{s/sleep 2/sleep 0.5/;}' \
        -e '/Wait for audio to come back/,/done/{s/sleep 2/sleep 0.5/;}' \
        -e '/debounce to let Bluetooth/,/done/{s/sleep 1/sleep 0.5/;}' \
        "$SCRIPT_DIR/keep-mic-warm.sh" > "$TEST_DIR/keep-mic-warm.sh"
    chmod +x "$TEST_DIR/keep-mic-warm.sh"
}

teardown() {
    if [ -n "$SCRIPT_PID" ] && kill -0 "$SCRIPT_PID" 2>/dev/null; then
        kill "$SCRIPT_PID" 2>/dev/null || true
        wait "$SCRIPT_PID" 2>/dev/null || true
    fi
    SCRIPT_PID=""

    if [ -n "$TEST_DIR" ]; then
        pkill -f "$TEST_DIR/bin/ffmpeg" 2>/dev/null || true
        rm -rf "$TEST_DIR"
    fi
    TEST_DIR=""
}

# ── Helpers ──────────────────────────────────────────────────────

start_script() {
    PATH="$TEST_DIR/bin:$SYSTEM_PATH" bash "$TEST_DIR/keep-mic-warm.sh" \
        > "$TEST_DIR/logs/output.log" 2>&1 &
    SCRIPT_PID=$!
}

# Wait for a pattern in the log. Timeout is in half-second ticks.
wait_for_log() {
    local pattern="$1"
    local ticks="${2:-20}"  # default 10 seconds (20 * 0.5s)
    local i=0
    while [ "$i" -lt "$ticks" ]; do
        if grep -q "$pattern" "$TEST_DIR/logs/output.log" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

get_ffmpeg_pid() {
    if [ -f "$TEST_DIR/mic-warm.pid" ]; then
        cat "$TEST_DIR/mic-warm.pid"
    else
        echo ""
    fi
}

assert_log() {
    local pattern="$1"
    local msg="${2:-Expected log pattern: $pattern}"
    if grep -q "$pattern" "$TEST_DIR/logs/output.log" 2>/dev/null; then
        return 0
    else
        echo ""
        echo "  ASSERT FAILED: $msg"
        echo "  Pattern: $pattern"
        echo "  Log contents:"
        sed 's/^/    /' "$TEST_DIR/logs/output.log" 2>/dev/null || echo "    (empty)"
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

# ── Test Cases ───────────────────────────────────────────────────

test_startup_valid_device() {
    echo "MacBook Pro Microphone" > "$TEST_DIR/device"
    start_script
    wait_for_log "Running (PID:" || return 1
    assert_log "Starting on: MacBook Pro Microphone" || return 1

    local pid
    pid=$(get_ffmpeg_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

test_missing_ffmpeg() {
    rm "$TEST_DIR/bin/ffmpeg"
    PATH="$TEST_DIR/bin:$SYSTEM_PATH" bash "$TEST_DIR/keep-mic-warm.sh" \
        > "$TEST_DIR/logs/output.log" 2>&1 || true
    assert_log "ffmpeg is required"
}

test_missing_switchaudiosource() {
    rm "$TEST_DIR/bin/SwitchAudioSource"
    PATH="$TEST_DIR/bin:$SYSTEM_PATH" bash "$TEST_DIR/keep-mic-warm.sh" \
        > "$TEST_DIR/logs/output.log" 2>&1 || true
    assert_log "SwitchAudioSource is required"
}

test_device_switch_airpods_to_builtin() {
    echo "Drew's AirPods Pro" > "$TEST_DIR/device"
    start_script
    wait_for_log "Running (PID:" || return 1

    local old_pid
    old_pid=$(get_ffmpeg_pid)
    [ -n "$old_pid" ] || { echo "  No initial ffmpeg PID"; return 1; }

    echo "MacBook Pro Microphone" > "$TEST_DIR/device"
    wait_for_log "Device change detected: Drew's AirPods Pro -> MacBook Pro Microphone" || return 1
    wait_for_log "Restarted on: MacBook Pro Microphone" 30 || return 1

    local new_pid
    new_pid=$(get_ffmpeg_pid)
    [ -n "$new_pid" ] || { echo "  No new ffmpeg PID"; return 1; }
    [ "$old_pid" != "$new_pid" ] || { echo "  PID didn't change: $old_pid"; return 1; }
}

test_device_switch_builtin_to_airpods() {
    echo "MacBook Pro Microphone" > "$TEST_DIR/device"
    start_script
    wait_for_log "Running (PID:" || return 1

    local old_pid
    old_pid=$(get_ffmpeg_pid)

    echo "Drew's AirPods Pro" > "$TEST_DIR/device"
    wait_for_log "Device change detected: MacBook Pro Microphone -> Drew's AirPods Pro" || return 1
    wait_for_log "Restarted on: Drew's AirPods Pro" 30 || return 1

    local new_pid
    new_pid=$(get_ffmpeg_pid)
    [ "$old_pid" != "$new_pid" ]
}

test_ffmpeg_dies_unexpectedly() {
    start_script
    wait_for_log "Running (PID:" || return 1

    local pid
    pid=$(get_ffmpeg_pid)
    [ -n "$pid" ] || return 1

    kill "$pid" 2>/dev/null
    wait_for_log "ffmpeg died unexpectedly" || return 1
    wait_for_log "Recovered (PID:" || return 1

    local new_pid
    new_pid=$(get_ffmpeg_pid)
    [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null
}

test_coreaudiod_restart() {
    start_script
    wait_for_log "Running (PID:" || return 1

    # Simulate coreaudiod going away (empty device)
    echo -n "" > "$TEST_DIR/device"
    wait_for_log "Could not read audio device" 30 || return 1

    # Simulate recovery
    sleep 1
    echo "MacBook Pro Microphone" > "$TEST_DIR/device"
    wait_for_log "Audio back. Device: MacBook Pro Microphone" 40 || return 1
    wait_for_log "Restarted on: MacBook Pro Microphone" 10 || return 1
}

test_ffmpeg_fails_to_start() {
    start_script
    wait_for_log "Running (PID:" || return 1

    # Make ffmpeg fail, then trigger restart via device change
    touch "$TEST_DIR/ffmpeg_fail"
    echo "USB Microphone" > "$TEST_DIR/device"
    wait_for_log "Device change detected:" || return 1
    wait_for_log "ffmpeg process exited immediately" 20 || return 1

    # Remove fail flag, trigger another device change for recovery
    rm -f "$TEST_DIR/ffmpeg_fail"
    echo "MacBook Pro Microphone" > "$TEST_DIR/device"
    wait_for_log "Restarted on: MacBook Pro Microphone" 20 || return 1
}

test_rapid_device_switching() {
    start_script
    wait_for_log "Running (PID:" || return 1

    for device in "USB Mic" "AirPods" "Built-in" "USB Mic" "AirPods"; do
        echo "$device" > "$TEST_DIR/device"
        sleep 0.3
    done

    # Give the script time to debounce and process
    sleep 6

    local final_pid
    final_pid=$(get_ffmpeg_pid)
    [ -n "$final_pid" ] && kill -0 "$final_pid" 2>/dev/null || return 1

    # Debounce should reduce the number of actual restarts
    local restarts
    restarts=$(grep -c "Restarted on:" "$TEST_DIR/logs/output.log" 2>/dev/null || echo 0)
    [ "$restarts" -ge 1 ] || { echo "  No restarts logged"; return 1; }

    # With debounce, we should see fewer restarts than raw device changes
    local detections
    detections=$(grep -c "Device change detected:" "$TEST_DIR/logs/output.log" 2>/dev/null || echo 0)
    [ "$detections" -ge 1 ] || { echo "  No device changes detected"; return 1; }
}

test_device_bounce_back() {
    # Simulates AirPods briefly appearing then bouncing back to built-in.
    # The debounce should prevent a needless restart.
    echo "MacBook Pro Microphone" > "$TEST_DIR/device"
    start_script
    wait_for_log "Running (PID:" || return 1

    local old_pid
    old_pid=$(get_ffmpeg_pid)

    # Briefly switch to AirPods, then back to built-in before debounce settles
    echo "Drew's AirPods Pro" > "$TEST_DIR/device"
    sleep 0.3
    echo "MacBook Pro Microphone" > "$TEST_DIR/device"

    # Wait for debounce to finish
    sleep 4

    wait_for_log "Device bounced back to: MacBook Pro Microphone" 10 || return 1

    # PID should NOT have changed since device settled back to original
    local current_pid
    current_pid=$(get_ffmpeg_pid)
    [ "$old_pid" = "$current_pid" ] || { echo "  PID changed unnecessarily: $old_pid -> $current_pid"; return 1; }
}

test_stale_pid_cleanup() {
    # PID file pointing to a dead process
    echo "99999" > "$TEST_DIR/mic-warm.pid"

    start_script
    wait_for_log "Running (PID:" || return 1

    local pid
    pid=$(get_ffmpeg_pid)
    [ -n "$pid" ] && [ "$pid" != "99999" ] && kill -0 "$pid" 2>/dev/null
}

test_stale_pid_cleanup_live_process() {
    # Start a real background process and use its PID as the "stale" ffmpeg
    sleep 300 &
    disown
    local stale_pid=$!

    echo "$stale_pid" > "$TEST_DIR/mic-warm.pid"

    start_script
    wait_for_log "Killing stale ffmpeg" || return 1
    wait_for_log "Running (PID:" || return 1

    # The stale process should have been killed
    if kill -0 "$stale_pid" 2>/dev/null; then
        kill "$stale_pid" 2>/dev/null || true
        echo "  Stale process was not killed"
        return 1
    fi
    return 0
}

# ── Runner ───────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}keep-mic-warm.sh test suite${RESET}"
echo "─────────────────────────────────────────────"

run_test "Startup on valid device"              test_startup_valid_device
run_test "Missing ffmpeg"                       test_missing_ffmpeg
run_test "Missing SwitchAudioSource"            test_missing_switchaudiosource
run_test "Device switch: AirPods -> Built-in"   test_device_switch_airpods_to_builtin
run_test "Device switch: Built-in -> AirPods"   test_device_switch_builtin_to_airpods
run_test "ffmpeg dies unexpectedly"             test_ffmpeg_dies_unexpectedly
run_test "coreaudiod restart recovery"          test_coreaudiod_restart
run_test "ffmpeg fails to start"                test_ffmpeg_fails_to_start
run_test "Rapid device switching"               test_rapid_device_switching
run_test "Device bounce-back (debounce)"        test_device_bounce_back
run_test "Stale PID cleanup (dead process)"     test_stale_pid_cleanup
run_test "Stale PID cleanup (live process)"     test_stale_pid_cleanup_live_process

echo "─────────────────────────────────────────────"
echo -e "Results: ${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
