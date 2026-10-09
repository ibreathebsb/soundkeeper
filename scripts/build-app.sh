#!/bin/sh
# Builds everything into the "build" directory:
#
#     build/SoundKeeper.app    the menu bar app
#     build/soundkeeper        the command line tool
#
# Only Command Line Tools are required (xcode-select --install), Xcode is not needed.

set -eu
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="build/SoundKeeper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/SoundKeeperApp" "$APP/Contents/MacOS/SoundKeeper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$APP/Contents/Resources/"

cp "$BIN/soundkeeper" build/soundkeeper

# An ad-hoc signature: the app is built on this Mac for this Mac.
codesign --force --sign - --identifier local.soundkeeper "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --strict "$APP"

echo "Built $APP and build/soundkeeper"
