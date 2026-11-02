# YTD

Paste a YouTube link and it downloads. A small Mac app, for macOS 13 or later.

## The app

The app is a small, plain white window: the title bar shows its name, ytd,
with no divider below it. It drags by any empty spot, and is always exactly
as big as its content. It stays on top of other windows: the pin at the right
of the title bar turns that off and on. The green button switches to a larger
layout, wider and with a taller list, and back. Along the top: a link field, **Paste**,
a quality menu, an options button, **Add** and **Download**.

- **One link:** copy it anywhere and it appears in the field, even while
  ytd sits on top of your browser (or press Paste), then Download (or
  Return). A copy never replaces something you've typed in the field.
- **Many links:** copy a whole list (from notes, a chat, a document, one per
  line or separated by spaces) and press Paste: they all go into the download
  list. Or put links in the field one at a time and press Add (⌘↩). Each keeps
  the quality and options it was added with.
- **Download** (Download All when the field is empty) starts everything
  waiting in the list, a few side by side: 3 by default, 1 to 5 under
  options. Each row shows the resolution yt-dlp picked, the estimated file size
  and its progress, and can be stopped, carried on, retried, removed or shown
  in Finder. While the list runs, the Dock icon counts what's
  left.
- The list is kept when you quit, so you can collect links now and download
  them later. A download cut off by quitting picks up from its partial file.

Files are saved as `Title [video-id] 1080p.mp4` in your Downloads folder, with
mp4/m4a preferred so they open in QuickTime.

The options button (it turns blue when something is switched on) offers:

| Option         | What it does                                                   |
| -------------- | -------------------------------------------------------------- |
| Save to        | the folder downloads go to: your Downloads folder unless you pick another |
| Subtitles      | embeds subtitles in the languages you list (`en`, `en,de`)    |
| Extras         | embeds the thumbnail, chapters and video info; cuts sponsor segments with SponsorBlock; downloads a whole playlist into its own folder |
| Video file     | Auto (mp4 when possible), MP4 or MKV                           |
| Audio file     | keeps the original, or converts to MP3, M4A, Opus, FLAC or WAV |
| Sign in        | uses your YouTube login from Safari, Chrome, Firefox, Brave or Edge, for age-restricted or members-only videos |
| Clip           | downloads only part of the video, e.g. `1:30` to `2:45` (for the next links added) |
| At once        | how many links in the list download side by side (1 to 5)      |

## Libraries

The app itself is only the window. It does its work with three libraries,
which it downloads on first launch (about a minute) into
`~/Library/Application Support/YTD`:

| Library | What for |
| ------- | -------- |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | the downloader |
| [ffmpeg](https://ffmpeg.martin-riedl.de) | merges video with audio, converts, cuts clips |
| [Deno](https://deno.com) | solves YouTube's JavaScript challenge, which unlocks all of its formats |

Each download is checked against its published SHA-256, and ffmpeg's and
Deno's Developer ID signatures are checked as well. Each library has its own
row in the window: the installed version, and whether it's the latest or which
newer version is available, with an Update button just for that library. Only
stable releases count: yt-dlp's release channel (never nightly builds),
numbered ffmpeg releases (never snapshots of its development branch), and
Deno's LTS line. The app looks for updates when it starts, and again when you
come back to it after an hour or more.

To remove it completely, delete the app and that folder.

## Build

```bash
./build.sh
```

This needs Xcode or its command line tools, and nothing else. It compiles
[app/](app) into a universal `dist/YTD.app`. Drag that to Applications. CI
builds it on every push, and a `v*` tag attaches it to a GitHub release.

The app has only an ad-hoc signature, not a Developer ID, so macOS blocks it
the first time if you downloaded it. To open it anyway, go to System
Settings → Privacy & Security → Open Anyway. You can also clear the quarantine
flag:

```bash
xattr -dr com.apple.quarantine /Applications/YTD.app
```

## Test

```bash
./test.sh
```
