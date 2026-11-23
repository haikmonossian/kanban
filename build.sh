#!/bin/bash
# Build Kanban.app (+ kb CLI inside the bundle).  ./build.sh install  → also installs to /Applications,
# links ~/.local/bin/kb and the Claude skill.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Kanban.app
FLAGS=(-O -swift-version 5 -target arm64-apple-macos26.0)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ app"
swiftc "${FLAGS[@]}" -parse-as-library Sources/Core/*.swift Sources/App/*.swift -lsqlite3 -o "$APP/Contents/MacOS/Kanban"
echo "→ kb"
swiftc "${FLAGS[@]}" Sources/Core/*.swift Sources/CLI/main.swift -lsqlite3 -o "$APP/Contents/MacOS/kb"

echo "→ icône"
if [ ! -f build/AppIcon.icns ] || [ Scripts/icon.swift -nt build/AppIcon.icns ]; then
  swift Scripts/icon.swift build/icon.png
  rm -rf build/AppIcon.iconset && mkdir build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "✓ $APP"

if [ "${1:-}" = "install" ]; then
  DEST=/Applications/Kanban.app
  pkill -x Kanban 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST" && cp -R "$APP" "$DEST"
  mkdir -p "$HOME/.local/bin" && ln -sf "$DEST/Contents/MacOS/kb" "$HOME/.local/bin/kb"
  mkdir -p "$HOME/.claude/skills/kanban" && cp skill/SKILL.md "$HOME/.claude/skills/kanban/SKILL.md"
  touch "$DEST"
  echo "✓ installé : $DEST, ~/.local/bin/kb, ~/.claude/skills/kanban"
fi
