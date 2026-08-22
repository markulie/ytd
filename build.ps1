# Windows half of build.sh: freezes ytd.py into a single console .exe.
#
# The frozen exe carries its own Python, so python/ isn't shipped; yt-dlp and
# ffmpeg are fetched next to the exe on first run (or into the user's data dir
# when the exe sits somewhere read-only like Program Files).
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$dist = Join-Path $here "dist"
$work = Join-Path $here "build"

python -m pip install --quiet --upgrade pyinstaller
if ($LASTEXITCODE -ne 0) { throw "could not install pyinstaller" }

# --console: the terminal window is the entire UI, so it must not be hidden
python -m PyInstaller `
    --onefile `
    --console `
    --name ytd `
    --distpath $dist `
    --workpath $work `
    --specpath $work `
    (Join-Path $here "ytd.py")
if ($LASTEXITCODE -ne 0) { throw "pyinstaller failed" }

Get-ChildItem $dist
