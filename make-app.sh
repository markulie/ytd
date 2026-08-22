#!/usr/bin/env bash
# Builds ytd.app — a double-clickable app that opens Terminal and runs y.
# The bundle carries its own copy of everything, so it works wherever it lands.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "macOS only — use build.sh, which picks the right format per platform." >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-$HERE/ytd.app}"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ytd</string>
    <key>CFBundleDisplayName</key><string>ytd</string>
    <key>CFBundleIdentifier</key><string>local.ytd</string>
    <key>CFBundleExecutable</key><string>ytd</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>10.15</string>
</dict>
</plist>
PLIST

# The bundle executable gets no terminal of its own when launched from Finder,
# so it hands the real work to Terminal and exits.
cat > "$APP/Contents/MacOS/ytd" <<'SH'
#!/bin/sh
RES=$(cd "$(dirname "$0")/../Resources" && pwd)
exec open -a Terminal "$RES/y"
SH
chmod +x "$APP/Contents/MacOS/ytd"

cp "$HERE/y" "$HERE/ytd.py" "$RES/"
chmod +x "$RES/y"

# -c clones on APFS: instant, and the copy costs no extra disk until changed.
# Missing runtimes are fine — the app re-fetches them on first launch.
for dir in python bin; do
    if [ -d "$HERE/$dir" ]; then
        cp -Rc "$HERE/$dir" "$RES/" 2>/dev/null || cp -R "$HERE/$dir" "$RES/"
    fi
done

echo "built $APP"
