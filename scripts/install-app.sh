#!/bin/bash
# Build "Mic Warm.app", install it in /Applications, and launch it.
#
#   scripts/install-app.sh
#
# Signs with the first "Apple Development" identity in the keychain when there is one (so the
# microphone permission survives rebuilds), else ad-hoc. Set MIC_WARM_SIGN_IDENTITY to override.
#
# Safe while the command-line mic-warm LaunchAgent runs: the app sees the agent and stands by
# until you pick "Switch to Mic Warm App" in its menu.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/Mic Warm.app"

if [[ -z "${MIC_WARM_SIGN_IDENTITY:-}" ]]; then
    MIC_WARM_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
export MIC_WARM_SIGN_IDENTITY="${MIC_WARM_SIGN_IDENTITY:--}"
echo "Signing with: $MIC_WARM_SIGN_IDENTITY"

"$ROOT/scripts/build-app.sh"

# Quit a running copy so the new build replaces it.
osascript -e 'tell application id "com.drewburchfield.micwarm" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 50); do
    pgrep -f "$DEST/Contents/MacOS/Mic Warm" >/dev/null || break
    sleep 0.1
done

rm -rf "$DEST"
ditto "$ROOT/.build/Mic Warm.app" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
