#!/bin/bash
# install-local.sh
# Builds mic-warm from source and installs as a persistent LaunchAgent.
# Run from the repo root: bash install-local.sh

set -e

BIN_DIR="$HOME/.local/bin"
BIN_PATH="$BIN_DIR/mic-warm"
PLIST_PATH="$HOME/Library/LaunchAgents/com.user.keep-mic-warm.plist"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building mic-warm..."
cd "$REPO_DIR"
swift build -c release 2>&1

BUILT_BIN="$REPO_DIR/.build/release/mic-warm"

# Stop any running instance
launchctl unload "$PLIST_PATH" 2>/dev/null || true
pkill -x mic-warm 2>/dev/null || true
sleep 0.5

mkdir -p "$BIN_DIR"
cp "$BUILT_BIN" "$BIN_PATH"
chmod +x "$BIN_PATH"

# Ad-hoc code sign so macOS TCC tracks a stable identity
codesign --force --sign - "$BIN_PATH"

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
echo "The mic-warm menu bar icon should appear shortly."
echo ""
echo "If you haven't granted mic access yet:"
echo "  System Settings > Privacy & Security > Microphone > allow mic-warm"
echo ""
echo "Log file: /tmp/mic-warm.log"
echo "To uninstall: bash $REPO_DIR/uninstall.sh"
