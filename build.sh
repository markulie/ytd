#!/usr/bin/env bash
# Builds dist/YTD.app from the Swift in app/. Needs Xcode or its command line
# tools, and nothing else. The app carries none of yt-dlp, ffmpeg or Deno: it
# fetches them into ~/Library/Application Support/YTD on first launch.
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
    echo "YTD can only be built on macOS." >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=YTD
EXECUTABLE=YTD
APP="$HERE/dist/$NAME.app"
RES="$APP/Contents/Resources"
WORK="$HERE/build"

rm -rf "$APP" "$WORK"
mkdir -p "$APP/Contents/MacOS" "$RES" "$WORK"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>local.ytd</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.4</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# A universal binary: compiled once per architecture, then joined by lipo.
# macOS 13 is the first with NSHostingView sizing options and Grid.
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -parse-as-library \
        -target "$arch-apple-macos13.0" \
        -o "$WORK/$EXECUTABLE-$arch" "$HERE"/app/*.swift
done
lipo -create -output "$APP/Contents/MacOS/$EXECUTABLE" "$WORK/$EXECUTABLE-arm64" "$WORK/$EXECUTABLE-x86_64"

# Icon: drawn at every size by make-icon.swift, then packed by iconutil.
swiftc -O -o "$WORK/make-icon" "$HERE/make-icon.swift"
"$WORK/make-icon" "$WORK/AppIcon.iconset" >/dev/null
iconutil -c icns "$WORK/AppIcon.iconset" -o "$RES/AppIcon.icns"

# Ad-hoc signature: no Developer ID, but it seals the bundle and gives macOS
# a stable identity for it, e.g. for the one-time Downloads folder prompt.
codesign --force --sign - "$APP"

echo "built $APP"
