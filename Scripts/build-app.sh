#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Stocker.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/StockerMac" "$APP/Contents/MacOS/StockerMac"
if [[ -d "$BIN_DIR/StockerMac_StockerMac.bundle" ]]; then
  cp -R "$BIN_DIR/StockerMac_StockerMac.bundle" "$APP/Contents/Resources/StockerMac_StockerMac.bundle"
fi
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/StockerMac"

codesign --force --deep --sign - "$APP"
echo "$APP"
