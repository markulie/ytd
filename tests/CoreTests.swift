// Checks for app/Core.swift, the logic that needs no network and no UI.
// Run with ./test.sh. A plain executable rather than XCTest, so it builds
// with swiftc alone, without an Xcode project.
import Foundation

@main
struct CoreTests {
    static var failures = 0
    static var checks = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String,
                                     line: Int = #line) {
        checks += 1
        if actual != expected {
            failures += 1
            print("FAIL line \(line): \(what)\n  got:      \(actual)\n  expected: \(expected)")
        }
    }

    static func main() {
        qualities()
        links()
        manyLinks()
        clips()
        options()
        outputTemplates()
        ytdlpLines()
        releases()
        toolStates()
        list()
        savedOptions()
        print(failures == 0 ? "all \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func qualities() {
        expect(Quality.best.formatArguments, ["-f", "bv*+ba/b", "-S", "res,ext:mp4:m4a"], "best is uncapped")
        expect(Quality.q720.formatArguments, ["-f", "bv*+ba/b", "-S", "res:720,ext:mp4:m4a"],
               "a cap sorts by the shorter side")
        expect(Quality.audio.formatArguments.contains("-x"), true, "audio extracts")
        expect(Quality.audio.formatArguments.contains("--audio-format"), false, "audio isn't re-encoded")
        expect(Quality.q1080.label, "1080p", "label")
    }

    static func links() {
        let cases: [(String, String?)] = [
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            ("  https://youtu.be/abc\n", "https://youtu.be/abc"),
            ("youtu.be/abc", "https://youtu.be/abc"),
            ("m.youtube.com/shorts/xyz", "https://m.youtube.com/shorts/xyz"),
            ("HTTPS://YOUTUBE.COM/watch?v=a", "HTTPS://YOUTUBE.COM/watch?v=a"),
            ("https://music.youtube.com/watch?v=a", "https://music.youtube.com/watch?v=a"),
            ("check this https://youtu.be/abc", nil),
            ("https://vimeo.com/1", nil),
            ("https://notyoutube.com/x", nil),
            ("https://youtube.com/", nil),
            ("\"https://youtu.be/abc\"", nil),
            ("hello", nil),
            ("", nil),
            ("https://youtu.be/abc https://youtu.be/def", nil),
        ]
        for (text, link) in cases {
            expect(YouTube.link(in: text), link, "link in \(text.debugDescription)")
        }
    }

    static func manyLinks() {
        let pasted = """
        Watch these:
        1. https://youtu.be/aaa
        2. "https://www.youtube.com/watch?v=bbb", youtu.be/ccc;
        (https://youtu.be/aaa) again, and https://vimeo.com/1
        """
        expect(YouTube.links(in: pasted),
               ["https://youtu.be/aaa", "https://www.youtube.com/watch?v=bbb", "https://youtu.be/ccc"],
               "links from a pasted list, in order, without repeats")
        expect(YouTube.links(in: "nothing here"), [], "no links")
        expect(YouTube.onlyLinks(in: "https://youtu.be/a  https://youtu.be/b"), true, "several links")
        expect(YouTube.onlyLinks(in: "https://youtu.be/a\nhttps://youtu.be/b,"), true, "one per line")
        expect(YouTube.onlyLinks(in: "https://youtu.be/a and more"), false, "other words")
        expect(YouTube.onlyLinks(in: "   "), false, "empty")
    }

    static func clips() {
        expect(Clip.section(start: "", end: ""), nil, "no clip")
        expect(Clip.section(start: "1:30", end: "2:45"), "1:30-2:45", "both ends")
        expect(Clip.section(start: "", end: "90"), "0-90", "from the start")
        expect(Clip.section(start: "1:02:03", end: ""), "1:02:03-inf", "to the end")
        expect(Clip.section(start: "abc", end: ""), "", "not a time")
        expect(Clip.section(start: "1:999", end: ""), "", "seconds too long")
    }

    static func options() {
        expect(Options().arguments(for: .best, clip: nil),
               ["--no-playlist", "-P", Options().folder, "-o", Options.fileName], "defaults")

        var video = Options()
        video.subtitles = true
        video.subtitleLanguages = "en, de"
        video.container = "mkv"
        video.embedInfo = true
        video.sponsorBlock = true
        video.playlist = true
        video.cookiesFrom = "firefox"
        let args = video.arguments(for: .q1080, clip: "0:05-0:12")
        func after(_ flag: String) -> String? {
            args.firstIndex(of: flag).map { args[$0 + 1] }
        }
        expect(args.first, "--yes-playlist", "whole playlist")
        expect(after("--sub-langs"), "en,de", "languages without spaces")
        expect(args.contains("--embed-subs"), true, "subtitles embedded")
        expect(args.contains("--write-subs"), false, "no .vtt left beside the video")
        expect(after("--merge-output-format"), "mkv", "container")
        expect(args.contains("--embed-thumbnail"), true, "thumbnail")
        expect(after("--sponsorblock-remove"), "default", "SponsorBlock")
        expect(after("--download-sections"), "*0:05-0:12", "clip")
        expect(after("--cookies-from-browser"), "firefox", "cookies")

        var audio = video
        audio.audioFormat = "mp3"
        let audioArgs = audio.arguments(for: .audio, clip: nil)
        expect(audioArgs.contains("--embed-subs"), false, "no subtitles in audio")
        expect(audioArgs.contains("--merge-output-format"), false, "no container for audio")
        expect(audioArgs.firstIndex(of: "--audio-format").map { audioArgs[$0 + 1] }, "mp3", "audio format")

        expect(video.changed, true, "changed")
        var moved = Options()
        moved.folder = "/tmp"
        expect(moved.changed, false, "the folder alone doesn't count as changed")

        var languages = Options()
        languages.subtitles = true
        for (text, valid) in [("en", true), ("en,de", true), ("en.*", true), ("en de", true), ("en;de", false), ("", false)] {
            languages.subtitleLanguages = text
            expect(languages.languagesValid, valid, "languages \(text.debugDescription)")
        }
        languages.subtitles = false
        expect(languages.languagesValid, true, "languages don't matter with subtitles off")
    }

    static func outputTemplates() {
        expect(Options().outputTemplate(clip: nil), Options.fileName, "plain")
        expect(Options().outputTemplate(clip: "1:30-2:45").hasSuffix(" (clip 1.30-2.45).%(ext)s"), true,
               "a clip gets its own name")
        var playlist = Options()
        playlist.playlist = true
        expect(playlist.outputTemplate(clip: nil).hasPrefix("%(playlist_title&{}/|)s"), true,
               "a playlist gets a folder")
    }

    static func ytdlpLines() {
        expect(YtdlpLine("@event progress  45.3% avc1.64001F"), .progress(percent: 45.3, audio: false), "video progress")
        expect(YtdlpLine("@event progress 100.0% none"), .progress(percent: 100, audio: true), "audio progress")
        expect(YtdlpLine("@event progress Unknown% none"), .ignored, "no figure yet")
        expect(YtdlpLine("@event title Me at the zoo"), .title("Me at the zoo"), "title")
        expect(YtdlpLine("@event file /a/b c.mp4"), .file("/a/b c.mp4"), "file")
        expect(YtdlpLine("ERROR: [youtube] x: Video unavailable"), .error("[youtube] x: Video unavailable"), "error")
        expect(YtdlpLine("WARNING: something"), .ignored, "warnings stay out of the way")
        expect(YtdlpLine("   "), .ignored, "blank")
        expect(YtdlpLine("[Merger] Merging formats"), .message("[Merger] Merging formats"), "other output")
    }

    static func releases() {
        expect(Release.ytdlpVersion(fromLatestURL: "https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26"),
               "2026.10.26", "yt-dlp tag")
        expect(Release.ytdlpVersion(fromLatestURL: "https://github.com/yt-dlp/yt-dlp/releases"), nil,
               "no tag in the URL")
        expect(Release.ffmpegBuild(fromLatestURL:
                "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip"),
               "1789931890_9.0.2", "ffmpeg release")
        expect(Release.ffmpegBuild(fromLatestURL:
                "https://ffmpeg.martin-riedl.de/download/macos/arm64/1793455460_N-128220-gbea9d176f7/ffmpeg.zip"),
               nil, "ffmpeg snapshots are never taken")
        expect(Release.ffmpegVersion(ofBuild: "1789931890_9.0.2"), "9.0.2", "ffmpeg version")
        expect(Release.denoVersion(fromLatestText: "v2.9.8\n"), "2.9.8", "deno tag")
        for junk in ["<html>", "v2.10.0-rc.1", ""] {
            expect(Release.denoVersion(fromLatestText: junk), nil, "deno junk \(junk.debugDescription)")
        }
        let sums = "AA11  yt-dlp_macos\nbb22  yt-dlp_macos.zip\ncc33 *other.zip\n"
        expect(Release.checksum(in: sums, for: "yt-dlp_macos.zip"), "bb22", "exact name")
        expect(Release.checksum(in: sums, for: "yt-dlp_macos"), "aa11", "lowercased")
        expect(Release.checksum(in: sums, for: "other.zip"), "cc33", "binary-mode marker")
        expect(Release.checksum(in: sums, for: "nope.zip"), nil, "missing")
    }

    static func list() {
        func item(_ link: String, _ state: Item.State) -> Item {
            var item = Item(link: link, quality: .best, options: Options(), clip: nil)
            item.state = state
            return item
        }
        let items = [item("a", .done), item("b", .downloading), item("c", .waiting),
                     item("d", .stopped), item("e", .waiting), item("f", .waiting)]
        expect(Queue.toStart(items, atOnce: 3), [items[2].id, items[4].id], "fills the free places, in order")
        expect(Queue.toStart(items, atOnce: 1), [], "nothing while the one place is taken")
        expect(Queue.toStart(items, atOnce: 5).count, 3, "only waiting ones, never stopped ones")

        var running = item("x", .downloading)
        running.progress = 0.5
        running.title = "Title"
        let saved = try! JSONDecoder().decode(Item.self, from: JSONEncoder().encode(running))
        expect(saved.title, "Title", "title is saved")
        expect(saved.progress, nil, "progress isn't saved")
        expect(saved.restored().state, .stopped, "a download cut off by quitting comes back stopped")
        expect(item("y", .failed).restored().state, .failed, "others come back as they were")

        let a = Item(link: "l", quality: .q720, options: Options(), clip: nil)
        expect(a.sameDownload(as: Item(link: "l", quality: .q720, options: Options(), clip: nil)), true, "same")
        expect(a.sameDownload(as: Item(link: "l", quality: .audio, options: Options(), clip: nil)), false,
               "another quality is another download")
        expect(a.arguments.first, "-f", "item arguments start with the format")
    }

    static func savedOptions() {
        let older = #"{"folder":"/x","subtitles":true,"subtitleLanguages":"de","embedInfo":false,"#
            + #""sponsorBlock":true,"playlist":false,"container":"mkv","audioFormat":"mp3","cookiesFrom":"none"}"#
        let options = try! JSONDecoder().decode(Options.self, from: Data(older.utf8))
        expect(options.folder, "/x", "kept from an older save")
        expect(options.container, "mkv", "kept from an older save")
        expect(options.atOnce, 3, "a choice added later gets its default")
        let wild = try! JSONDecoder().decode(Options.self, from: Data(#"{"atOnce": 99}"#.utf8))
        expect(wild.atOnce, 5, "at most 5 at once")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        expect(Options().folder, downloads, "saves to the Downloads folder by default")
        let oldDefault = try! JSONDecoder().decode(
            Options.self, from: JSONEncoder().encode(["folder": downloads + "/yt-dlp"]))
        expect(oldDefault.folder, downloads, "the old default folder moves to Downloads itself")
        var many = Options()
        many.atOnce = 5
        expect(many.changed, false, "how many at once isn't a download choice")
    }

    static func toolStates() {
        expect(Tool.state(installed: nil, latest: "1"), .missing, "missing")
        expect(Tool.state(installed: "1", latest: nil), .unknown, "offline")
        expect(Tool.state(installed: "1", latest: "1"), .latest, "latest")
        expect(Tool.state(installed: "1", latest: "2"), .update, "update")
    }
}
