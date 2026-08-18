#!/usr/bin/env bash
# 打包 release .app 并安装到 /Applications（替换旧版后启动新版）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./Scripts/build-app.sh

echo "==> 退出旧实例"
osascript -e 'quit app "Stocker"' 2>/dev/null || true
sleep 1
pkill -f "Stocker.app/Contents/MacOS/StockerMac" 2>/dev/null || true
sleep 1

echo "==> 安装到 /Applications"
rm -rf /Applications/Stocker.app
cp -R "$ROOT/dist/Stocker.app" /Applications/
chmod +x /Applications/Stocker.app/Contents/MacOS/StockerMac
codesign --verify --deep /Applications/Stocker.app
xattr -dr com.apple.quarantine /Applications/Stocker.app 2>/dev/null || true

echo "==> 启动新版"
open /Applications/Stocker.app
echo "✅ 已安装并启动 /Applications/Stocker.app"
