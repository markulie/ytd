#!/usr/bin/env bash
# One entry point for packaging. Produces the native artifact for whatever
# platform it runs on, into dist/:
#     macOS  -> dist/ytd.app
#     Linux  -> dist/ytd-<arch>.AppImage
# Windows is build.ps1 (a .exe needs a Windows toolchain).
#
# Artifacts stay thin when python/ and bin/ aren't present: the tools are
# fetched on first launch. Build after running ./y once to bundle them in.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$HERE/dist"
mkdir -p "$DIST"

case "$(uname -s)" in
Darwin)
    bash "$HERE/make-app.sh" "$DIST/ytd.app"
    ;;

Linux)
    ARCH="$(uname -m)"
    APPDIR="$HERE/build/AppDir"
    rm -rf "$APPDIR"
    mkdir -p "$APPDIR/usr/bin"

    # An AppImage is mounted read-only, so Python has to be inside it rather
    # than fetched later. --help exits before any yt-dlp/ffmpeg work, which
    # makes it the cheapest way to trigger just the Python bootstrap.
    [ -x "$HERE/python/bin/python3" ] || "$HERE/y" --help >/dev/null

    cp "$HERE/y" "$HERE/ytd.py" "$APPDIR/usr/bin/"
    chmod +x "$APPDIR/usr/bin/y"
    cp -r "$HERE/python" "$APPDIR/usr/bin/python"
    [ -d "$HERE/bin" ] && cp -r "$HERE/bin" "$APPDIR/usr/bin/bin"

    "$HERE/python/bin/python3" "$HERE/make-icon.py" "$APPDIR/ytd.png" >/dev/null
    cp "$APPDIR/ytd.png" "$APPDIR/.DirIcon"

    cat > "$APPDIR/ytd.desktop" <<'ENTRY'
[Desktop Entry]
Type=Application
Name=ytd
Comment=Paste a YouTube URL, it downloads
Exec=y
Icon=ytd
Terminal=true
Categories=AudioVideo;Network;
ENTRY

    cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
HERE=$(dirname "$(readlink -f "$0")")
exec "$HERE/usr/bin/y" "$@"
APPRUN
    chmod +x "$APPDIR/AppRun"

    TOOL="$HERE/build/appimagetool"
    if [ ! -x "$TOOL" ]; then
        curl -fL --progress-bar -o "$TOOL" \
            "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
        chmod +x "$TOOL"
    fi
    # runners usually lack FUSE, so let appimagetool unpack itself instead
    APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$ARCH" \
        "$TOOL" "$APPDIR" "$DIST/ytd-$ARCH.AppImage"
    ;;

*)
    echo "unsupported system: $(uname -s) — on Windows run build.ps1" >&2
    exit 1
    ;;
esac

ls -lh "$DIST"
