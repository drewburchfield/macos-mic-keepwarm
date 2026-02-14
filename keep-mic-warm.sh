#!/bin/bash
# keep-mic-warm.sh
# LEGACY FALLBACK - Use the native mic-warm binary instead (see README.md).
# This script requires ffmpeg and SwitchAudioSource from Homebrew, and mic
# permissions break on every brew upgrade because ffmpeg moves to a new path.
#
# Prevents macOS from sleeping the microphone hardware between uses.
# Automatically detects audio device changes (e.g. AirPods connect/disconnect)
# and restarts the keep-warm stream on the new device.

POLL_INTERVAL=2
DEBOUNCE_WAIT=3    # seconds to wait for device to settle after a change
DEBOUNCE_CHECKS=3  # re-check this many times during debounce

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

# Check for ffmpeg
if ! command -v ffmpeg &>/dev/null; then
    log "Error: ffmpeg is required. Install with: brew install ffmpeg"
    exit 1
fi

# Check for SwitchAudioSource
if ! command -v SwitchAudioSource &>/dev/null; then
    log "Error: SwitchAudioSource is required. Install with: brew install switchaudio-osx"
    exit 1
fi

FFMPEG_PID=""

cleanup() {
    log "Shutting down..."
    if [ -n "$FFMPEG_PID" ] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        kill "$FFMPEG_PID" 2>/dev/null
    fi
    rm -f /tmp/mic-warm.pid
    exit 0
}
trap cleanup EXIT INT TERM

get_device() {
    local device
    device=$(SwitchAudioSource -c -t input 2>/dev/null)
    if [ -z "$device" ]; then
        echo ""
        return 1
    fi
    echo "$device"
    return 0
}

stop_ffmpeg() {
    if [ -n "$FFMPEG_PID" ]; then
        if kill -0 "$FFMPEG_PID" 2>/dev/null; then
            kill "$FFMPEG_PID" 2>/dev/null
            # Wait up to 2 seconds for it to die
            for i in 1 2 3 4; do
                kill -0 "$FFMPEG_PID" 2>/dev/null || break
                sleep 0.5
            done
            # Force kill if still alive
            kill -9 "$FFMPEG_PID" 2>/dev/null || true
        fi
        FFMPEG_PID=""
    fi
    rm -f /tmp/mic-warm.pid
}

start_ffmpeg() {
    stop_ffmpeg
    ffmpeg -f avfoundation -i ":0" -f null /dev/null 2>/dev/null &
    FFMPEG_PID=$!
    sleep 0.5
    if kill -0 "$FFMPEG_PID" 2>/dev/null; then
        echo "$FFMPEG_PID" > /tmp/mic-warm.pid
        return 0
    else
        log "ffmpeg process exited immediately"
        FFMPEG_PID=""
        rm -f /tmp/mic-warm.pid
        return 1
    fi
}

# Kill any stale instance from a previous run
if [ -f /tmp/mic-warm.pid ]; then
    OLD_PID=$(cat /tmp/mic-warm.pid)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "Killing stale ffmpeg (PID: $OLD_PID)"
        kill "$OLD_PID" 2>/dev/null || true
        sleep 0.5
    fi
    rm -f /tmp/mic-warm.pid
fi

# Wait for audio subsystem to be ready
CURRENT_DEVICE=""
for i in 1 2 3 4 5; do
    CURRENT_DEVICE=$(get_device)
    if [ -n "$CURRENT_DEVICE" ]; then
        break
    fi
    log "Waiting for audio subsystem... (attempt $i)"
    sleep 2
done

if [ -z "$CURRENT_DEVICE" ]; then
    log "Error: Could not detect audio input device after 10 seconds."
    exit 1
fi

log "Starting on: $CURRENT_DEVICE"

if ! start_ffmpeg; then
    log "Error: ffmpeg failed to start. Check microphone permissions."
    exit 1
fi

log "Running (PID: $FFMPEG_PID). Monitoring for device changes..."

FAIL_COUNT=0

while true; do
    sleep "$POLL_INTERVAL"

    # Check current device
    NEW_DEVICE=$(get_device)

    # If SwitchAudioSource fails (e.g. coreaudiod restarting), skip this cycle
    if [ -z "$NEW_DEVICE" ]; then
        log "Could not read audio device (coreaudiod restarting?). Waiting..."
        stop_ffmpeg
        # Wait for audio to come back
        for i in 1 2 3 4 5 6 7 8 9 10; do
            sleep 2
            NEW_DEVICE=$(get_device)
            if [ -n "$NEW_DEVICE" ]; then
                break
            fi
            log "Still waiting for audio subsystem... (${i}0s)"
        done
        if [ -z "$NEW_DEVICE" ]; then
            log "Audio subsystem not responding. Will keep trying..."
            continue
        fi
        CURRENT_DEVICE="$NEW_DEVICE"
        log "Audio back. Device: $CURRENT_DEVICE"
        if start_ffmpeg; then
            log "Restarted on: $CURRENT_DEVICE (PID: $FFMPEG_PID)"
            FAIL_COUNT=0
        else
            log "Warning: ffmpeg failed to start on $CURRENT_DEVICE"
        fi
        continue
    fi

    # Device changed - debounce to let Bluetooth handoffs settle
    if [ "$NEW_DEVICE" != "$CURRENT_DEVICE" ]; then
        log "Device change detected: $CURRENT_DEVICE -> $NEW_DEVICE (waiting ${DEBOUNCE_WAIT}s to settle)"
        SETTLED_DEVICE="$NEW_DEVICE"
        for i in $(seq 1 "$DEBOUNCE_CHECKS"); do
            sleep 1
            SETTLED_DEVICE=$(get_device)
            if [ -z "$SETTLED_DEVICE" ]; then
                SETTLED_DEVICE=""
                break
            fi
        done
        # If device went offline during debounce, let the next loop iteration handle it
        if [ -z "$SETTLED_DEVICE" ]; then
            log "Device went offline during handoff. Waiting for recovery..."
            continue
        fi
        # Only switch if the settled device differs from what we're currently on
        if [ "$SETTLED_DEVICE" != "$CURRENT_DEVICE" ]; then
            log "Device settled on: $SETTLED_DEVICE (was: $CURRENT_DEVICE)"
            CURRENT_DEVICE="$SETTLED_DEVICE"
            if start_ffmpeg; then
                log "Restarted on: $CURRENT_DEVICE (PID: $FFMPEG_PID)"
                FAIL_COUNT=0
            else
                log "Warning: ffmpeg failed to start on $CURRENT_DEVICE"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        else
            log "Device bounced back to: $CURRENT_DEVICE (no restart needed)"
        fi
        continue
    fi

    # Check ffmpeg is alive
    if [ -n "$FFMPEG_PID" ] && ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log "ffmpeg died unexpectedly. Restarting on: $CURRENT_DEVICE"
        if start_ffmpeg; then
            log "Recovered (PID: $FFMPEG_PID)"
            FAIL_COUNT=0
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            log "Restart failed (attempt $FAIL_COUNT)"
            if [ "$FAIL_COUNT" -ge 5 ]; then
                log "Too many failures. Waiting 10s before retry..."
                sleep 10
                FAIL_COUNT=0
            fi
        fi
    fi
done
