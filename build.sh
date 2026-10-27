#!/bin/zsh
# Builds build/Monibar.app and build/Monibar.dmg, the release artifact the
# updater downloads.
#
# Usage: ./build.sh [--install]
#   --install: also copies the bundle to /Applications and relaunches it.

set -euo pipefail
cd "$(dirname "$0")"

APP=build/Monibar.app
DMG=build/Monibar.dmg
BUNDLE_ID="dev.monibar.app"
VERSION="0.1.7"
BUILD="8"

echo "▶ Building release…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Monibar"

echo "▶ Packaging $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Monibar"
strip -x "$APP/Contents/MacOS/Monibar"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Monibar</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Monibar</string>
    <key>CFBundleDisplayName</key><string>Monibar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
# English keys in the code, translations in Resources/<lang>.lproj.
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# App icon: the menu bar chip, rendered by the binary at 1024 px.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
"$BIN" --generate-icon "$ICONSET/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    [ $size = 512 ] || sips -z $double $double "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# An Apple Development certificate when there is one, else ad hoc.
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
if [ -n "$SIGN_IDENTITY" ]; then
    echo "▶ Signing with \"$SIGN_IDENTITY\"…"
    codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null
else
    echo "▶ Ad hoc signing."
    codesign --force --sign - "$APP" >/dev/null
fi

# Without LaunchServices knowing the bundle, UNUserNotificationCenter refuses
# notifications ("bundle proxy not found").
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP" 2>/dev/null || true
echo "✓ $APP ready."

# Drag-and-drop DMG: Monibar.app next to an Applications alias.
echo "▶ Packaging $DMG…"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Monibar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✓ $DMG ready ($(du -h "$DMG" | cut -f1))."

if [ "${1:-}" = "--install" ]; then
    pkill -x Monibar || true
    rm -rf /Applications/Monibar.app
    cp -R "$APP" /Applications/
    open /Applications/Monibar.app
    echo "✓ /Applications/Monibar.app installed."
fi
