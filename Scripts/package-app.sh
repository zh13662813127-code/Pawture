#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
swift build -c release --product DesktopCats -Xswiftc -DPAWTURE_APP_BUNDLE -Xswiftc -gnone
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PWD/build/Pawture.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/DesktopCats" "$APP_DIR/Contents/MacOS/DesktopCats"
cp Scripts/Info.plist "$APP_DIR/Contents/Info.plist"
cp Sources/DesktopCats/Resources/*.png "$APP_DIR/Contents/Resources/"
strip -S "$APP_DIR/Contents/MacOS/DesktopCats"
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
printf 'Created %s\n' "$APP_DIR"
