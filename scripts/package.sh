#!/bin/sh
# Packs build/SoundKeeper.app and build/soundkeeper into a zip for distribution: dist/SoundKeeper-<version>-macos-<arch>.zip
# The only thing it prints to the standard output is the path of the zip. Run "make app" first.

set -eu
cd "$(dirname "$0")/.."

if [ ! -d build/SoundKeeper.app ] || [ ! -x build/soundkeeper ]; then
	echo "There is nothing to pack. Run 'make app' first." >&2
	exit 1
fi

version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"

case "$(lipo -archs build/SoundKeeper.app/Contents/MacOS/SoundKeeper)" in
	*arm64*x86_64* | *x86_64*arm64*) arch="universal" ;;
	*) arch="$(lipo -archs build/SoundKeeper.app/Contents/MacOS/SoundKeeper | tr -d ' ')" ;;
esac

name="SoundKeeper-$version-macos-$arch"

rm -rf "dist/$name" "dist/$name.zip"
mkdir -p "dist/$name"

ditto build/SoundKeeper.app "dist/$name/SoundKeeper.app"
cp build/soundkeeper LICENSE README.md README.zh-CN.md "dist/$name/"

# The app is signed, so make sure that it survived the copying.
codesign --verify --strict "dist/$name/SoundKeeper.app" >&2

# Without extended attributes: other unzip tools would turn them into "._" files that break the signature.
(cd dist && ditto -c -k --norsrc --noextattr --noacl --keepParent "$name" "$name.zip")
rm -rf "dist/$name"

echo "dist/$name.zip"
