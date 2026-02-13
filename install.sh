#!/bin/bash
# install.sh
# Installs keep-mic-warm as a persistent background service (LaunchAgent).
# Runs on login, restarts automatically if killed.
# Auto-detects audio device changes (AirPods connect/disconnect).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/keep-mic-warm.sh"

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: keep-mic-warm.sh not found at $SCRIPT_PATH"
    exit 1
fi

if ! command -v ffmpeg &>/dev/null; then
    echo "Error: ffmpeg is required. Install with: brew install ffmpeg"
    exit 1
fi

if ! command -v SwitchAudioSource &>/dev/null; then
    echo "SwitchAudioSource not found. Installing..."
    brew install switchaudio-osx
fi

chmod +x "$SCRIPT_PATH"

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
        <string>/bin/bash</string>
        <string>${SCRIPT_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/mic-warm.log</string>
    <key>StandardOutPath</key>
    <string>/tmp/mic-warm.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF

launchctl load "$PLIST_PATH"

echo "Installed and running."
echo "The mic will stay warm across reboots."
echo "Automatically switches when you connect/disconnect AirPods or Bluetooth audio."
echo ""
echo "macOS will ask you to grant ffmpeg microphone access on first run."
echo "Click 'Allow' when prompted."
echo ""
echo "Log file: /tmp/mic-warm.log"
echo "To uninstall: ./uninstall.sh"
