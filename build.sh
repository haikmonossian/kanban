#!/bin/bash
# ./build.sh            → build/Kanban.app (machine courante)
# ./build.sh install    → + /Applications/Kanban.app, ~/.local/bin/kb, skill Claude
# ./build.sh release    → app universelle (Apple Silicon + Intel) + build/Kanban-<version>.dmg + .sha256
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP=build/Kanban.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ARCHS=(arm64)
[ "$MODE" = "release" ] && ARCHS=(arm64 x86_64)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

# compile <out> <extra flags...> -- <sources...> : one slice per arch, merged with lipo
compile() {
  local out=$1; shift
  local slices=()
  for a in "${ARCHS[@]}"; do
    swiftc -O -swift-version 5 -target "$a-apple-macos26.0" "$@" -lsqlite3 -o "build/obj/$(basename "$out")-$a"
    slices+=("build/obj/$(basename "$out")-$a")
  done
  lipo -create "${slices[@]}" -output "$out"
}

echo "→ app (${ARCHS[*]})"
compile "$APP/Contents/MacOS/Kanban" -parse-as-library Sources/Core/*.swift Sources/App/*.swift
echo "→ kb"
compile "$APP/Contents/MacOS/kb" Sources/Core/*.swift Sources/CLI/main.swift

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
cp skill/SKILL.md "$APP/Contents/Resources/SKILL.md"
cp Resources/Info.plist "$APP/Contents/"
# Ad-hoc signature (no Apple Developer ID): required to run on Apple Silicon, not notarized.
# Inner binary first, then the bundle (no --deep), hardened runtime on both.
codesign --force --options runtime -s - "$APP/Contents/MacOS/kb"
codesign --force --options runtime -s - "$APP"
echo "✓ $APP"

if [ "$MODE" = "install" ]; then
  DEST=/Applications/Kanban.app
  pkill -x Kanban 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST" && cp -R "$APP" "$DEST"
  mkdir -p "$HOME/.local/bin" && ln -sf "$DEST/Contents/MacOS/kb" "$HOME/.local/bin/kb"
  mkdir -p "$HOME/.claude/skills/kanban" && cp skill/SKILL.md "$HOME/.claude/skills/kanban/SKILL.md"
  touch "$DEST"
  echo "✓ installé : $DEST, ~/.local/bin/kb, ~/.claude/skills/kanban"
fi

if [ "$MODE" = "release" ]; then
  DMG="build/Kanban-$VERSION.dmg"
  STAGE=build/dmg && rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "Kanban $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
  (cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
  echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
  lipo -archs "$APP/Contents/MacOS/Kanban"
fi
