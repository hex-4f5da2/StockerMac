#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RAW_GLYPH="${1:-Sources/StockerMac/Resources/StatusIcon.png}"
TEMP_DIR="$ROOT/scratch/icon_build"
ICONSET="$TEMP_DIR/AppIcon.iconset"
STANDARDIZED_PNG="$TEMP_DIR/standard_icon.png"

rm -rf "$TEMP_DIR"
mkdir -p "$ICONSET"

echo "==> 1. 生成单层纯净 macOS HIG 标准图标 (824x824 squircle in 1024x1024 canvas with shadow)"
sips -j "$ROOT/Scripts/render-icon.js" "$RAW_GLYPH" --out "$STANDARDIZED_PNG" >/dev/null

echo "==> 2. 生成多分辨率 iconset"
sips -z 16 16     "$STANDARDIZED_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$STANDARDIZED_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$STANDARDIZED_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$STANDARDIZED_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$STANDARDIZED_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$STANDARDIZED_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$STANDARDIZED_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$STANDARDIZED_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$STANDARDIZED_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$STANDARDIZED_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

echo "==> 3. 打包 AppIcon.icns 与更新 App/AppIcon.png"
iconutil -c icns "$ICONSET" -o "$ROOT/App/AppIcon.icns"
cp "$STANDARDIZED_PNG" "$ROOT/App/AppIcon.png"

rm -rf "$TEMP_DIR"
echo "✅ 图标生成完毕: App/AppIcon.icns & App/AppIcon.png"
