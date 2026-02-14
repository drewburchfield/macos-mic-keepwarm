#!/bin/bash
# install.sh
# Downloads and installs mic-warm as a persistent background service (LaunchAgent).
# No Homebrew dependencies required.

set -e

REPO="drewburchfield/macos-mic-keepwarm"
BIN_DIR="$HOME/.local/bin"
BIN_PATH="$BIN_DIR/mic-warm"
PLIST_PATH="$HOME/Library/LaunchAgents/com.user.keep-mic-warm.plist"

echo "Installing mic-warm..."

# Migrate from old ffmpeg-based method if present
if [ -f "$PLIST_PATH" ] && grep -q "keep-mic-warm.sh" "$PLIST_PATH" 2>/dev/null; then
    echo "Migrating from legacy shell script..."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    # Kill any leftover ffmpeg from the old method
    if [ -f /tmp/mic-warm.pid ]; then
        OLD_PID=$(cat /tmp/mic-warm.pid 2>/dev/null || true)
        [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null || true
    fi
    pkill -f "ffmpeg.*avfoundation.*:0.*null" 2>/dev/null || true
    rm -f /tmp/mic-warm.pid /tmp/mic-warm.log
    echo "Old method stopped."
fi

# Download precompiled universal binary from latest release
mkdir -p "$BIN_DIR"
curl -fsSL "https://github.com/$REPO/releases/latest/download/mic-warm" -o "$BIN_PATH"
chmod +x "$BIN_PATH"

# Ad-hoc code sign so macOS TCC tracks a stable identity
codesign --force --sign - "$BIN_PATH"

# Unload existing agent if present
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
        <string>${BIN_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/mic-warm.log</string>
    <key>StandardOutPath</key>
    <string>/tmp/mic-warm.log</string>
</dict>
</plist>
EOF

launchctl load "$PLIST_PATH"

echo ""
echo "Installed and running."
echo "The mic will stay warm across reboots."
echo ""
echo "macOS will prompt you to grant mic-warm microphone access."
echo "Go to System Settings > Privacy & Security > Microphone and allow it."
echo ""
echo "Log file: /tmp/mic-warm.log"
echo "To uninstall: curl -fsSL https://raw.githubusercontent.com/drewburchfield/macos-mic-keepwarm/master/uninstall.sh | bash"
