#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/installers
xcodebuild -project DemichevVoice.xcodeproj -scheme DemichevVoice \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/Release ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build > build/release.log 2>&1
APP="$PWD/build/Release/Build/Products/Release/Demichev Voice.app"
PLIST="$APP/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = ru.demichev.voice
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")" = 'Demichev Voice'
test "$(lipo -archs "$APP/Contents/MacOS/DemichevVoice")" = arm64
codesign --verify --strict --deep "$APP"
cmp LICENSE "$APP/Contents/Resources/LICENSE"
for license in Resources/Licenses/*.txt; do cmp "$license" "$APP/Contents/Resources/$(basename "$license")"; done
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
STAGE=$(mktemp -d "$PWD/build/dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Demichev Voice.app"
ln -s /Applications "$STAGE/Applications"
cp RELEASE-NOTES.txt "$STAGE/Установка.txt"
cp LICENSE "$STAGE/LICENSE.txt"
cp -R Resources/Licenses "$STAGE/Licenses"
cp Resources/ModelCredits.txt "$STAGE/ModelCredits.txt"
DMG="$PWD/build/installers/Demichev-Voice-$VERSION-arm64.dmg"
test ! -e "$DMG"
hdiutil create -srcfolder "$STAGE" -volname 'Demichev Voice' -format UDZO "$DMG"
hdiutil verify "$DMG"
cd build/installers
shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256"
shasum -a 256 -c "$(basename "$DMG").sha256"
