#!/usr/bin/env bash
# Puts `y` on your PATH. Everything else (python, yt-dlp, ffmpeg) is fetched
# on demand by the launcher itself, so this is pure convenience.
# On Windows there is nothing to install: run or double-click y.cmd.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$HERE/y" "$HERE/ytd.py"

case "$(uname -s)" in
    Darwin)
        # /usr/local/bin is root-owned but already on the default PATH
        TARGET=/usr/local/bin/y
        sudo ln -sfn "$HERE/y" "$TARGET"
        ;;
    Linux)
        # no sudo needed, and most distros already have this on PATH
        TARGET="$HOME/.local/bin/y"
        mkdir -p "$(dirname "$TARGET")"
        ln -sfn "$HERE/y" "$TARGET"
        case ":$PATH:" in
            *":$(dirname "$TARGET"):"*) ;;
            *) echo "note: $(dirname "$TARGET") is not on your PATH yet" ;;
        esac
        ;;
    *)
        echo "unsupported system: $(uname -s) — on Windows just run y.cmd" >&2
        exit 1
        ;;
esac

# No fetching here: python, yt-dlp and ffmpeg all install themselves on the
# first run, so putting y on PATH is the whole job.
echo "installed: $TARGET -> $HERE/y"
