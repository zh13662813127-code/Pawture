#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --target DesktopCatsCore
BIN="$(swift build -c release --show-bin-path)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -O -I "$BIN/Modules" "$BIN"/DesktopCatsCore.build/*.swift.o \
  Sources/DesktopCats/CatPoseAnalyzer.swift Sources/DesktopCats/StandingRenderer.swift \
  Sources/DesktopCats/CatRestRenderer.swift Sources/DesktopCats/CatContact.swift \
  Tests/RenderChecks/VisibleFurChecks.swift Tests/RenderChecks/main.swift -o "$TMP/check-poses"
mkdir -p build/preview
"$TMP/check-poses" Sources/DesktopCats/Resources build/preview/quiet-companions.png
