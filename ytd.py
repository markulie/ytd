#!/usr/bin/env python3
"""
y - paste a YouTube URL, it downloads immediately. Ctrl+C to quit.
Defaults to the best available quality. Type a quality (1080, 720, audio,
...) to switch, or put one after a URL for a one-off. Type `update` to
upgrade the bundled tools.

Self-contained — everything lives in this folder and nothing is installed
system wide:
    python/       the Python running this file (a system python is never used)
    bin/yt-dlp/   official standalone yt-dlp, carries its own Python
    bin/ffmpeg/   static ffmpeg + ffprobe, needed to merge video with audio
Copy the folder anywhere and it works; delete any of the three and it is
re-fetched on the next run.

Runs on macOS, Linux and Windows: the right builds for the current platform
are picked below and fetched on demand. Launch via ./y (y.cmd on Windows).
"""
from __future__ import annotations  # keeps the type hints lazy for older python3

import argparse
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import zipfile
from pathlib import Path

# Where the code lives. resolve() follows the /usr/local/bin/y symlink back to
# the real project dir, so the bundled tools are found however y is invoked;
# in a PyInstaller build __file__ points inside the unpacked bundle, so the
# executable's own folder is the right anchor instead.
if getattr(sys, "frozen", False):
    APP_DIR = Path(sys.executable).resolve().parent
else:
    APP_DIR = Path(__file__).resolve().parent

# Where downloads land. Normally right beside the code, but an AppImage is
# mounted read-only, so fall back to the user's data dir and stay self-healing.
if os.environ.get("APPIMAGE") or not os.access(APP_DIR, os.W_OK):
    DATA_DIR = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "ytd"
else:
    DATA_DIR = APP_DIR

BIN_DIR = DATA_DIR / "bin"

SYSTEM = platform.system()  # Darwin | Linux | Windows
WINDOWS = SYSTEM == "Windows"
ARM = platform.machine().lower() in ("arm64", "aarch64")

# yt-dlp ships a "onedir" zip per platform: it unpacks once here, so startup
# is ~0.3s. The single-file builds re-extract themselves on every run.
YTDLP_ASSET = {
    ("Darwin", False): ("yt-dlp_macos.zip", "yt-dlp_macos"),
    ("Darwin", True): ("yt-dlp_macos.zip", "yt-dlp_macos"),  # universal2 binary
    ("Linux", False): ("yt-dlp_linux.zip", "yt-dlp_linux"),
    ("Linux", True): ("yt-dlp_linux_aarch64.zip", "yt-dlp_linux_aarch64"),
    ("Windows", False): ("yt-dlp_win.zip", "yt-dlp.exe"),
    ("Windows", True): ("yt-dlp_win_arm64.zip", "yt-dlp.exe"),
}[(SYSTEM, ARM)]
RELEASE_URL = f"https://github.com/yt-dlp/yt-dlp/releases/latest/download/{YTDLP_ASSET[0]}"

# macOS/Linux: martin-riedl.de publishes static builds behind a stable "latest"
# redirect, one bare binary per zip, so updating is just following it again.
# Windows: yt-dlp's own ffmpeg builds, a single zip holding both exes nested
# inside a versioned folder, stamped by the asset's upstream mtime.
FFMPEG_OS = {"Darwin": "macos", "Linux": "linux"}.get(SYSTEM)
FFMPEG_ARCH = "arm64" if ARM else "amd64"
FFMPEG_URL = (f"https://ffmpeg.martin-riedl.de/redirect/latest/{FFMPEG_OS}/"
              f"{FFMPEG_ARCH}/release/{{tool}}.zip")
FFMPEG_WIN_ASSET = f"ffmpeg-master-latest-win{'arm64' if ARM else '64'}-gpl.zip"
FFMPEG_WIN_API = "https://api.github.com/repos/yt-dlp/FFmpeg-Builds/releases/latest"
FFMPEG_WIN_URL = ("https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/"
                  + FFMPEG_WIN_ASSET)

EXE = ".exe" if WINDOWS else ""
YTDLP_DIR = BIN_DIR / "yt-dlp"
YTDLP = YTDLP_DIR / YTDLP_ASSET[1]
FFMPEG_DIR = BIN_DIR / "ffmpeg"
FFMPEG = FFMPEG_DIR / f"ffmpeg{EXE}"
FFMPEG_STAMP = FFMPEG_DIR / ".build"  # which upstream build is unpacked here

DOWNLOAD_DIR = Path.home() / "Downloads" / "yt-dlp"

URL_RE = re.compile(r"(https?://\S*(youtube\.com|youtu\.be)\S*)")

AUDIO = "audio"
QUALITIES = ["best", "2160", "1440", "1080", "720", "480", "360", AUDIO]
ALIASES = {"4k": "2160", "2k": "1440", "hd": "1080", "max": "best",
           "mp3": AUDIO, "sound": AUDIO, "a": AUDIO}
DEFAULT_QUALITY = "best"

UPDATE_WORDS = ("update", "upgrade", "u")
HELP_WORDS = ("q", "quality", "help", "?")
VERSION_WORDS = ("version", "v")


def normalize(word: str) -> str | None:
    """User-typed quality word -> key in QUALITIES, or None if it isn't one."""
    w = word.strip().lower().lstrip("-")
    if w.endswith("p") and w[:-1].isdigit():
        w = w[:-1]
    w = ALIASES.get(w, w)
    return w if w in QUALITIES else None


def format_args(quality: str) -> list[str]:
    if quality == AUDIO:
        return ["-f", "ba/b", "-x"]  # no --audio-format: keep native codec, no re-encode
    if quality == "best":
        return ["-f", "bv*+ba/b"]
    return ["-f", f"bv*[height<={quality}]+ba/b[height<={quality}]"]


def label(quality: str) -> str:
    return quality if quality in ("best", AUDIO) else f"{quality}p"


def prompt(quality: str) -> None:
    print(f"\n[{label(quality)}] Paste next URL (Ctrl+C to quit):")


def show_help(quality: str) -> None:
    print("Qualities: " + "  ".join(
        f"*{label(q)}*" if q == quality else label(q) for q in QUALITIES))
    print("Type one to switch, or append it to a URL for a single download.")
    print("Commands: update (upgrade yt-dlp + ffmpeg)  version  q (this list)")


def ytdlp_version() -> str | None:
    """Version of the bundled yt-dlp, or None if it isn't installed yet."""
    if not YTDLP.exists():
        return None
    done = subprocess.run([str(YTDLP), "--version"], capture_output=True, text=True)
    return done.stdout.strip() or None


def _staging(name: str):
    """A scratch dir beside the target, so a failed download can't break bin/."""
    path = DATA_DIR / f"{name}.new"
    shutil.rmtree(path, ignore_errors=True)
    path.mkdir(parents=True)
    return path


def _unzip(archive: Path, into: Path) -> None:
    """Extract, keeping the executable bit that ZipInfo carries in its mode.

    zipfile is used rather than the unzip command because Windows has no
    unzip, and minimal Linux images often don't either.
    """
    with zipfile.ZipFile(archive) as zf:
        for member in zf.infolist():
            target = zf.extract(member, into)
            mode = member.external_attr >> 16
            if mode & stat.S_IXUSR:
                Path(target).chmod(mode & 0o7777)


def _grab(url: str, into: Path) -> bool:
    """Download a zip and unpack it into `into`."""
    archive = into / "download.zip"
    if subprocess.run(["curl", "-fL", "--progress-bar", "-o", str(archive), url]).returncode:
        return False
    try:
        _unzip(archive, into)
    except (zipfile.BadZipFile, OSError) as err:
        print(f"Could not unpack the download: {err}")
        return False
    archive.unlink()
    return True


def fetch_ytdlp() -> bool:
    """Download the standalone yt-dlp build into bin/yt-dlp/."""
    staging = _staging("yt-dlp")
    print("Downloading yt-dlp...")
    if not _grab(RELEASE_URL, staging) or not (staging / YTDLP.name).exists():
        shutil.rmtree(staging, ignore_errors=True)
        print("Download failed — check your connection and try again.")
        return False

    BIN_DIR.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(YTDLP_DIR, ignore_errors=True)
    staging.replace(YTDLP_DIR)
    YTDLP.chmod(0o755)
    print("Checking it runs (macOS scans new binaries once — takes a few seconds)...")
    return True


def update_ytdlp() -> bool:
    """Self-update the bundled yt-dlp, downloading it first if it's missing."""
    if not YTDLP.exists():
        if not fetch_ytdlp():
            return False
        print(f"yt-dlp {ytdlp_version()} installed.")
        return True

    before = ytdlp_version()
    print("Updating yt-dlp...")
    done = subprocess.run([str(YTDLP), "-U"])  # standalone builds update themselves in place
    if done.returncode != 0:
        print("Self-update failed; re-downloading instead.")
        if not fetch_ytdlp():
            return False

    after = ytdlp_version()
    print(f"yt-dlp {after} — already current." if before == after
          else f"yt-dlp {after} (was {before}).")
    return after is not None


def ffmpeg_build() -> str | None:
    """Upstream build id of the unpacked ffmpeg, e.g. '1785863997_9.0'."""
    if not (FFMPEG.exists() and FFMPEG_STAMP.exists()):
        return None
    return FFMPEG_STAMP.read_text().strip() or None


def ffmpeg_version(build: str | None = None) -> str | None:
    build = build or ffmpeg_build()
    if not build:
        return "?" if FFMPEG.exists() else None
    if re.match(r"\d+_", build):
        return build.split("_", 1)[1]  # 1785863997_9.0 -> 9.0
    return f"master@{build[:10]}"  # windows stamp is an ISO timestamp


def latest_ffmpeg_build() -> str | None:
    """Identify the newest upstream ffmpeg, as a string we can compare."""
    if WINDOWS:
        # this release tag never moves, so ask the API when its asset changed
        done = subprocess.run(["curl", "-sfL", FFMPEG_WIN_API],
                              capture_output=True, text=True)
        if done.returncode != 0:
            return None
        try:
            assets = json.loads(done.stdout)["assets"]
        except (ValueError, KeyError):
            return None
        for asset in assets:
            if asset.get("name") == FFMPEG_WIN_ASSET:
                return asset.get("updated_at")
        return None

    # a 1-byte ranged GET, not HEAD: the server sometimes answers HEAD without
    # redirecting, which would leave us reading the un-resolved URL
    done = subprocess.run(
        ["curl", "-sL", "-o", os.devnull, "-r", "0-0", "-w", "%{url_effective}",
         FFMPEG_URL.format(tool="ffmpeg")],
        capture_output=True, text=True)
    if done.returncode != 0:
        return None
    parts = done.stdout.strip().split("/")
    candidate = parts[-2] if len(parts) > 2 else ""
    return candidate if re.match(r"\d+_", candidate) else None  # e.g. 1785863997_9.0


def _collect_ffmpeg(staging: Path) -> bool:
    """Get ffmpeg/ffprobe to sit at the top of `staging`, whatever the layout.

    macOS and Linux zips hold one bare binary each; the Windows zip nests both
    inside <name>/bin/, so hoist them out.
    """
    for tool in (f"ffmpeg{EXE}", f"ffprobe{EXE}"):
        found = staging / tool
        if not found.exists():
            found = next(iter(sorted(staging.rglob(tool))), None)
            if found is None:
                return False
            found.replace(staging / tool)
        (staging / tool).chmod(0o755)

    for leftover in staging.iterdir():  # drop the unpacked folder, docs, etc.
        if leftover.name not in (f"ffmpeg{EXE}", f"ffprobe{EXE}"):
            shutil.rmtree(leftover, ignore_errors=True) if leftover.is_dir() else leftover.unlink()
    return True


def update_ffmpeg() -> bool:
    """Fetch ffmpeg + ffprobe if missing or if upstream has a newer build."""
    latest = latest_ffmpeg_build()
    current = ffmpeg_build()

    if latest is None:  # offline: keep whatever is already unpacked
        if current:
            print(f"ffmpeg {ffmpeg_version()} — could not check for updates.")
            return True
        print("Could not reach the ffmpeg download server.")
        return False

    if current == latest:
        print(f"ffmpeg {ffmpeg_version()} — already current.")
        return True

    staging = _staging("ffmpeg")
    print("Updating ffmpeg..." if current else "Downloading ffmpeg...")
    # one zip holds both tools on Windows; macOS and Linux publish them apart
    sources = [FFMPEG_WIN_URL] if WINDOWS else [FFMPEG_URL.format(tool=t)
                                                for t in ("ffmpeg", "ffprobe")]
    for source in sources:
        if not _grab(source, staging):
            shutil.rmtree(staging, ignore_errors=True)
            print("Download failed — check your connection and try again.")
            return False
    if not _collect_ffmpeg(staging):
        shutil.rmtree(staging, ignore_errors=True)
        print("The ffmpeg download didn't contain the expected binaries.")
        return False

    (staging / FFMPEG_STAMP.name).write_text(latest)
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(FFMPEG_DIR, ignore_errors=True)
    staging.replace(FFMPEG_DIR)
    print(f"ffmpeg {ffmpeg_version()}" + (f" (was {ffmpeg_version(current)})." if current
                                          else " installed."))
    return True


def update_all() -> bool:
    return all([update_ytdlp(), update_ffmpeg()])


def download(url: str, quality: str) -> None:
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)  # re-ensure every time, cheap and avoids races
    out_template = str(DOWNLOAD_DIR / "%(title)s.%(ext)s")
    cmd = [
        str(YTDLP),
        "--no-playlist",
        "--ffmpeg-location", str(FFMPEG_DIR),  # our copy, never a system one
        *format_args(quality),
        "-o", out_template,
        url,
    ]
    print(f"\n→ downloading ({label(quality)}): {url}\n")
    subprocess.run(cmd)  # no cwd= — output path is already absolute


def main() -> None:
    parser = argparse.ArgumentParser(prog="y", description="Paste YouTube URLs, download them.")
    parser.add_argument("-q", "--quality", default=DEFAULT_QUALITY,
                        help="starting quality: %s (default: %s)"
                             % (", ".join(QUALITIES), DEFAULT_QUALITY))
    parser.add_argument("-u", "--update", action="store_true",
                        help="upgrade the bundled yt-dlp and exit")
    args = parser.parse_args()

    if args.update:
        sys.exit(0 if update_all() else 1)

    quality = normalize(args.quality)
    if quality is None:
        parser.error(f"unknown quality {args.quality!r}; pick one of: {', '.join(QUALITIES)}")

    if ytdlp_version() is None:  # first run, or someone deleted bin/
        print("yt-dlp isn't set up in this project yet.")
        if not update_ytdlp():
            sys.exit(1)
    if ffmpeg_build() is None:  # needed to merge video+audio into one file
        print("ffmpeg isn't set up in this project yet.")
        if not update_ffmpeg():
            sys.exit(1)

    bundled = ("bundled" if getattr(sys, "frozen", False)
               or Path(sys.executable).is_relative_to(APP_DIR) else "system")
    print(f"y — downloads to {DOWNLOAD_DIR}")
    print(f"    yt-dlp {ytdlp_version()} · ffmpeg {ffmpeg_version()} · "
          f"python {platform.python_version()} ({bundled})")
    show_help(quality)
    print("\nPaste a YouTube URL and hit Enter:\n")
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue

            match = URL_RE.search(line)
            if not match:
                picked = normalize(line)
                word = line.lower()
                if picked:
                    quality = picked
                    print(f"Quality set to {label(quality)}.")
                elif word in UPDATE_WORDS:
                    update_all()
                elif word in VERSION_WORDS:
                    print(f"yt-dlp {ytdlp_version()} · ffmpeg {ffmpeg_version()} · "
                          f"python {platform.python_version()}")
                elif word in HELP_WORDS:
                    show_help(quality)
                else:
                    print("Not a YouTube URL, ignored. Try again:")
                continue

            # a quality word next to the URL applies to this download only
            rest = (line[:match.start(1)] + line[match.end(1):]).split()
            one_off = next((normalize(w) for w in rest if normalize(w)), None)
            download(match.group(1), one_off or quality)
            prompt(quality)
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
