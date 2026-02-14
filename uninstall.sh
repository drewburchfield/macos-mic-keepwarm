#!/bin/bash
# uninstall.sh
# Removes the mic-warm background service.

set -e

PLIST_PATH="$HOME/Library/LaunchAgents/com.user.keep-mic-warm.plist"

if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "Uninstalled. Mic will return to default sleep behavior."
else
    echo "mic-warm is not installed (no plist found)."
fi

rm -f /tmp/mic-warm.pid
rm -f /tmp/mic-warm.log

if [ -f "$HOME/.local/bin/mic-warm" ]; then
    rm -f "$HOME/.local/bin/mic-warm"
    echo "Removed mic-warm binary."
fi
