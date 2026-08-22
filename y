#!/bin/sh
# y - launcher. Runs ytd.py on the project's own Python, never the system one,
# and fetches that Python the first time if it isn't here yet.
set -eu

PY_VERSION=3.14.7
PY_RELEASE=20260805

# follow symlinks (/usr/local/bin/y) back to the real project directory
SELF=$0
while [ -L "$SELF" ]; do
    LINK=$(readlink "$SELF")
    case $LINK in
        /*) SELF=$LINK ;;
        *)  SELF=$(dirname "$SELF")/$LINK ;;
    esac
done
HERE=$(cd "$(dirname "$SELF")" && pwd)

PYTHON=$HERE/python/bin/python3

if [ ! -x "$PYTHON" ]; then
    case $(uname -m) in
        arm64|aarch64) ARCH=aarch64 ;;
        x86_64|amd64)  ARCH=x86_64 ;;
        *) echo "unsupported cpu: $(uname -m)" >&2; exit 1 ;;
    esac
    case $(uname -s) in
        Darwin) TRIPLE=$ARCH-apple-darwin ;;
        Linux)  TRIPLE=$ARCH-unknown-linux-gnu ;;
        *) echo "unsupported system: $(uname -s) — on Windows run y.cmd" >&2; exit 1 ;;
    esac
    # %2B is the "+" in the build tag; GitHub needs it percent-encoded
    URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PY_RELEASE/cpython-$PY_VERSION%2B$PY_RELEASE-$TRIPLE-install_only.tar.gz"

    echo "Setting up the bundled Python $PY_VERSION (one time)..."
    STAGE=$HERE/python.new  # unpack aside, swap in only once it's whole
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    if ! curl -fL --progress-bar -o "$STAGE/python.tar.gz" "$URL" \
       || ! tar -xzf "$STAGE/python.tar.gz" -C "$STAGE" \
       || [ ! -x "$STAGE/python/bin/python3" ]; then
        rm -rf "$STAGE"
        echo "Could not set up Python — check your connection and try again." >&2
        exit 1
    fi
    rm -rf "$HERE/python"
    mv "$STAGE/python" "$HERE/python"
    rm -rf "$STAGE"
fi

exec "$PYTHON" "$HERE/ytd.py" "$@"
