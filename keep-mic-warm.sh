#!/bin/bash
# keep-mic-warm.sh
# Prevents macOS from sleeping the microphone hardware between uses.
# Solves the 2-5 second activation delay in push-to-talk transcription apps.

set -e

# Check for ffmpeg
if ! command -v ffmpeg &>/dev/null; then
    echo "Error: ffmpeg is required. Install with: brew install ffmpeg"
    exit 1
fi

# Kill any existing instance
if [ -f /tmp/mic-warm.pid ]; then
    OLD_PID=$(cat /tmp/mic-warm.pid)
    if [ -n "$OLD_PID" ] && ps -p "$OLD_PID" -o comm= 2>/dev/null | grep -q "ffmpeg"; then
        kill "$OLD_PID" 2>/dev/null || true
        sleep 0.2
    fi
    rm -f /tmp/mic-warm.pid
fi

ffmpeg -f avfoundation -i ":0" -f null /dev/null 2>/dev/null &
PID=$!
sleep 0.5

if ps -p "$PID" > /dev/null 2>&1; then
    echo "$PID" > /tmp/mic-warm.pid
    echo "Mic keep-warm running (PID: $PID)"
    echo "To stop: kill \$(cat /tmp/mic-warm.pid)"
else
    echo "Error: ffmpeg failed to start. Check microphone permissions in System Settings > Privacy & Security."
    exit 1
fi
