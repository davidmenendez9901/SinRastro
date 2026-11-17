#!/bin/sh
# Compila SinRastro en Release y la empaqueta en dist/SinRastro-<versión>.dmg.
set -eu
cd "$(dirname "$0")/.."

xcodebuild -project SinRastro.xcodeproj -scheme SinRastro -configuration Release \
    -derivedDataPath build build | grep -E "error|BUILD"

app="build/Build/Products/Release/SinRastro.app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

ditto "$app" "$staging/SinRastro.app"
ln -s /Applications "$staging/Applications"
mkdir -p dist
hdiutil create -volname "SinRastro" -srcfolder "$staging" -ov -format UDZO "dist/SinRastro-$version.dmg" >/dev/null
echo "dist/SinRastro-$version.dmg"
