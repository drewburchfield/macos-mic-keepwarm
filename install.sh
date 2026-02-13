#!/bin/bash
# install.sh
# Installs keep-mic-warm as a persistent background service (LaunchAgent).
# Runs on login, restarts automatically if killed.

set -e

FFMPEG_PATH=$(which ffmpeg 2>/dev/null)
if [ -z "$FFMPEG_PATH" ]; then
    echo "Error: ffmpeg is required. Install with: brew install ffmpeg"
    exit 1
fi

PLIST_PATH="$HOME/Library/LaunchAgents/com.user.keep-mic-warm.plist"

# Unload existing if present
launchctl unload "$PLIST_PATH" 2>/dev/null || true

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.keep-mic-warm</string>
    <key>ProgramArguments</key>
    <array>
        <string>${FFMPEG_PATH}</string>
        <string>-f</string>
        <string>avfoundation</string>
        <string>-i</string>
        <string>:0</string>
        <string>-f</string>
        <string>null</string>
        <string>/dev/null</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF

launchctl load "$PLIST_PATH"

echo "Installed and running."
echo "The mic will stay warm across reboots."
echo ""
echo "macOS will ask you to grant ffmpeg microphone access on first run."
echo "Click 'Allow' when prompted."
echo ""
echo "To uninstall: ./uninstall.sh"
