// The pure logic of YTD, with no UI and no side effects, so it can be tested
// on its own (tests/CoreTests.swift): qualities, link matching, the extra
// yt-dlp options, reading yt-dlp's output, and reading release versions.
import Foundation

enum Quality: String, CaseIterable, Identifiable, Codable {
    case best, q2160 = "2160", q1440 = "1440", q1080 = "1080", q720 = "720",
         q480 = "480", q360 = "360", audio

    var id: String { rawValue }
    var label: String {
        switch self {
        case .best: return "Best"
        case .audio: return "Audio"
        default: return rawValue + "p"
        }
    }

    /// yt-dlp's format choice. res is a video's shorter side, so a cap of 1080
    /// also gets a vertical 1080x1920 video right; mp4 then wins ties, so files
    /// open in QuickTime. Audio prefers AAC in .m4a, which -x keeps as is.
    var formatArguments: [String] {
        switch self {
        case .audio: return ["-f", "ba/b", "-x", "-S", "ext:m4a"]
        case .best: return ["-f", "bv*+ba/b", "-S", "res,ext:mp4:m4a"]
        default: return ["-f", "bv*+ba/b", "-S", "res:\(rawValue),ext:mp4:m4a"]
        }
    }
}

extension NSRegularExpression {
    convenience init(_ pattern: String, caseInsensitive: Bool = false) {
        try! self.init(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func matches(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func group(_ index: Int, in text: String) -> String? {
        guard let match = firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}

enum YouTube {
    // The whole text must be the link, so copying a paragraph that merely
    // mentions one doesn't land in the field.
    private static let pattern = NSRegularExpression(
        #"^(?:https?://)?(?:[\w-]+\.)*(?:youtube\.com|youtu\.be)/[^\s"'<>]+$"#, caseInsensitive: true)

    /// The link, with https:// added if it was left off, or nil.
    static func link(in text: String) -> String? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pattern.matches(candidate) else { return nil }
        return candidate.lowercased().hasPrefix("http") ? candidate : "https://" + candidate
    }

    /// The words of a text, split at spaces, new lines, commas and
    /// semicolons, with quotes and brackets around each one taken off.
    private static func words(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[]")) }
            .filter { !$0.isEmpty }
    }

    /// Every YouTube link in a text — a list copied from notes, a document,
    /// a chat — in order and without repeats. Other words are skipped.
    static func links(in text: String) -> [String] {
        var seen = Set<String>()
        return words(in: text).compactMap(link(in:)).filter { seen.insert($0).inserted }
    }

    /// True when a text holds at least one YouTube link and nothing else.
    static func onlyLinks(in text: String) -> Bool {
        let words = words(in: text)
        return !words.isEmpty && words.allSatisfy { link(in: $0) != nil }
    }
}

enum Clip {
    private static let time = NSRegularExpression(#"^\d+(?::\d{1,2}){0,2}$"#)  // 90, 1:30, 1:02:03

    /// "START-END" for yt-dlp's --download-sections; nil when both are empty
    /// (the whole video), "" when either doesn't look like a time.
    static func section(start: String, end: String) -> String? {
        let start = start.trimmingCharacters(in: .whitespaces)
        let end = end.trimmingCharacters(in: .whitespaces)
        if start.isEmpty && end.isEmpty { return nil }
        guard start.isEmpty || time.matches(start), end.isEmpty || time.matches(end) else { return "" }
        return "\(start.isEmpty ? "0" : start)-\(end.isEmpty ? "inf" : end)"
    }
}

/// The extra yt-dlp features, remembered between launches.
struct Options: Codable, Equatable {
    /// Your Downloads folder, the same one Safari uses.
    var folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
    var subtitles = false
    var subtitleLanguages = "en"
    var embedInfo = false
    var sponsorBlock = false
    var playlist = false
    var container = "auto"
    var audioFormat = "original"
    var cookiesFrom = "none"
    var atOnce = 3  // how many downloads run side by side

    /// The id keeps two videos that share a title apart, and the height keeps
    /// one video's 1080p and 720p apart, so switching quality really downloads
    /// again. Audio has no height, so its name ends at the id.
    static let fileName = "%(title)s [%(id)s]%(height& {}p|)s.%(ext)s"
    private static let languageList = NSRegularExpression(#"^[\w*.-]+(,[\w*.-]+)*$"#)

    var languages: String { subtitleLanguages.filter { !$0.isWhitespace } }
    var languagesValid: Bool { !subtitles || Self.languageList.matches(languages) }

    /// Any of the download choices, so not the folder (always shown anyway)
    /// or how many downloads run at once.
    var changed: Bool {
        var plain = self
        plain.folder = Options().folder
        plain.atOnce = Options().atOnce
        return plain != Options()
    }

    /// yt-dlp flags for these options; `clip` comes from Clip.section.
    func arguments(for quality: Quality, clip: String?) -> [String] {
        var args = [playlist ? "--yes-playlist" : "--no-playlist"]
        if quality == .audio {
            if audioFormat != "original" {
                args += ["--audio-format", audioFormat, "--audio-quality", "0"]
            }
        } else {
            if subtitles {
                // --embed-subs fetches written subtitles itself and deletes the
                // file once it's in the video (adding --write-subs would keep
                // it); auto-generated captions stand in where nobody wrote any
                args += ["--write-auto-subs", "--sub-langs", languages, "--embed-subs"]
            }
            if container != "auto" {
                args += ["--merge-output-format", container, "--remux-video", container]
            }
        }
        if embedInfo { args += ["--embed-thumbnail", "--embed-metadata", "--embed-chapters"] }
        if sponsorBlock { args += ["--sponsorblock-remove", "default"] }  // every category but filler
        if let clip = clip { args += ["--download-sections", "*\(clip)", "--force-keyframes-at-cuts"] }
        if cookiesFrom != "none" { args += ["--cookies-from-browser", cookiesFrom] }
        // -P rather than a path inside -o: a % in the folder name stays literal
        return args + ["-P", folder, "-o", outputTemplate(clip: clip)]
    }

    func outputTemplate(clip: String?) -> String {
        var name = Self.fileName
        if let clip = clip {  // a clip mustn't be mistaken for the whole video, or vice versa
            name = name.replacingOccurrences(of: ".%(ext)s",
                                             with: " (clip \(clip.replacingOccurrences(of: ":", with: "."))).%(ext)s")
        }
        return playlist ? "%(playlist_title&{}/|)s" + name : name  // a playlist gets its own folder
    }
}

extension Options {
    /// Any choice missing from what was saved (one added in a later version)
    /// falls back to its default, rather than losing all the others.
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? saved.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let plain = Options()
        folder = value(.folder, plain.folder)
        // the default used to be a yt-dlp folder inside Downloads
        if folder == (plain.folder as NSString).appendingPathComponent("yt-dlp") { folder = plain.folder }
        subtitles = value(.subtitles, plain.subtitles)
        subtitleLanguages = value(.subtitleLanguages, plain.subtitleLanguages)
        embedInfo = value(.embedInfo, plain.embedInfo)
        sponsorBlock = value(.sponsorBlock, plain.sponsorBlock)
        playlist = value(.playlist, plain.playlist)
        container = value(.container, plain.container)
        audioFormat = value(.audioFormat, plain.audioFormat)
        cookiesFrom = value(.cookiesFrom, plain.cookiesFrom)
        atOnce = min(max(value(.atOnce, plain.atOnce), 1), 5)
    }
}

/// One link in the download list, with the choices it was added with:
/// changing the quality or options later doesn't change what's queued.
struct Item: Identifiable, Codable, Equatable {
    enum State: String, Codable { case waiting, downloading, stopped, done, failed }

    var id = UUID()
    let link: String
    let quality: Quality
    let options: Options
    let clip: String?
    var title: String?
    var state = State.waiting
    var file: String?
    var error: String?
    /// What yt-dlp picked, known once a download starts: "1920x1080", or
    /// "audio only"; and its estimated size in bytes.
    var resolution: String?
    var size: Int64?
    // while downloading only, so not saved
    var progress: Double?
    var audio = false

    private enum CodingKeys: String, CodingKey {
        case id, link, quality, options, clip, title, state, file, error, resolution, size
    }

    init(link: String, quality: Quality, options: Options, clip: String?) {
        self.link = link
        self.quality = quality
        self.options = options
        self.clip = clip
    }

    /// yt-dlp's flags for this item, before the shared ones.
    var arguments: [String] {
        quality.formatArguments + options.arguments(for: quality, clip: clip)
    }

    /// "1920×1080", "audio", or the quality asked for until yt-dlp has picked.
    var resolutionText: String {
        guard let resolution = resolution else { return quality.label }
        return resolution == "audio only" ? "audio" : resolution.replacingOccurrences(of: "x", with: "×")
    }

    /// "≈ 245 MB" — yt-dlp's estimate before the file exists. Not shown for
    /// a clip: the estimate is for the whole video.
    var sizeText: String? {
        guard let size = size, size > 0, clip == nil else { return nil }
        return "≈ " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// The same download: same link, quality and clip.
    func sameDownload(as other: Item) -> Bool {
        link == other.link && quality == other.quality && clip == other.clip
    }

    /// As read back from a saved list: one that was downloading when the
    /// app quit has stopped, and picks up from its partial file later.
    func restored() -> Item {
        var item = self
        if item.state == .downloading { item.state = .stopped }
        return item
    }
}

enum Queue {
    /// Which items to start now: waiting ones, in list order, up to the
    /// number that may run at once.
    static func toStart(_ items: [Item], atOnce: Int) -> [Item.ID] {
        let running = items.filter { $0.state == .downloading }.count
        let free = max(atOnce - running, 0)
        return Array(items.filter { $0.state == .waiting }.prefix(free).map(\.id))
    }
}

/// One line of yt-dlp's output, run with `eventArguments`.
enum YtdlpLine: Equatable {
    case progress(percent: Double, audio: Bool)
    case title(String)
    case details(resolution: String?, size: Int64?)
    case file(String)
    case error(String)
    case message(String)
    case ignored

    /// Starts each line yt-dlp prints for the app, so it can't be mistaken
    /// for yt-dlp's own output.
    private static let marker = "@event "

    /// --print implies --quiet, so --progress brings back the progress, one
    /// line per update. vcodec "none" says the audio stream is downloading.
    static let eventArguments = [
        "--newline", "--progress", "--color", "never",
        "--progress-template", "download:\(marker)progress %(progress._percent_str)s %(info.vcodec)s",
        "--print", "before_dl:\(marker)title %(title)s",
        // size first: a resolution can have spaces in it ("audio only")
        "--print", "before_dl:\(marker)details %(filesize,filesize_approx|NA)s %(resolution|NA)s",
        "--print", "after_move:\(marker)file %(filepath)s",
    ]
    private static let percent = NSRegularExpression(#"(\d+(?:\.\d+)?)%"#)

    init(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix(Self.marker) {
            let body = line.dropFirst(Self.marker.count)
            let kind = body.prefix { $0 != " " }
            let value = body.dropFirst(kind.count).trimmingCharacters(in: .whitespaces)
            switch kind {
            case "progress":
                guard let figure = Self.percent.group(1, in: value).flatMap(Double.init) else {
                    self = .ignored
                    return
                }
                self = .progress(percent: min(figure, 100), audio: value.hasSuffix(" none"))
            case "title": self = .title(value)
            case "details":
                let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
                let resolution = parts.count > 1 && parts[1] != "NA" ? parts[1] : nil
                // yt-dlp's estimate may come with a fraction
                self = .details(resolution: resolution, size: parts.first.flatMap(Double.init).map { Int64($0) })
            case "file": self = .file(value)
            default: self = .ignored
            }
        } else if line.hasPrefix("ERROR:") {
            self = .error(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
        } else if line.isEmpty || line.hasPrefix("WARNING:") {
            self = .ignored
        } else {
            self = .message(line)
        }
    }
}

/// Reading what the release servers say. Only stable releases ever match.
enum Release {
    private static let ytdlpTag = NSRegularExpression(#"/tag/(\d{4}\.\d{2}\.\d{2}(?:\.\d+)?)$"#)
    // Numbered releases only: the server also publishes snapshots of ffmpeg's
    // development branch ("…_N-128220-gbea9d176f7"), and those never match.
    private static let ffmpegBuild = NSRegularExpression(#"/(\d+_\d+(?:\.\d+)*)/[^/]+$"#)
    private static let denoTag = NSRegularExpression(#"^v(\d+\.\d+\.\d+)$"#)

    /// .../releases/tag/2026.10.26 -> "2026.10.26"
    static func ytdlpVersion(fromLatestURL url: String) -> String? {
        ytdlpTag.group(1, in: url)
    }

    /// .../download/macos/arm64/1789931890_9.0.2/ffmpeg.zip -> "1789931890_9.0.2"
    static func ffmpegBuild(fromLatestURL url: String) -> String? {
        ffmpegBuild.group(1, in: url)
    }

    /// "v2.9.8\n" -> "2.9.8"
    static func denoVersion(fromLatestText text: String) -> String? {
        denoTag.group(1, in: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "1789931890_9.0.2" -> "9.0.2"
    static func ffmpegVersion(ofBuild build: String) -> String {
        build.split(separator: "_", maxSplits: 1).last.map(String.init) ?? build
    }

    /// The hash listed for `name` in a sha256sum-style file.
    static func checksum(in sums: String, for name: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count == 2, parts[1].drop(while: { $0 == "*" }) == name {
                return parts[0].lowercased()
            }
        }
        return nil
    }
}

struct Tool: Equatable {
    enum State: String { case checking, latest, update, unknown, missing }
    var state = State.checking
    var current: String?
    var latest: String?

    static func state(installed: String?, latest: String?) -> State {
        guard let installed = installed else { return .missing }
        guard let latest = latest else { return .unknown }  // offline: can't tell
        return installed == latest ? .latest : .update
    }
}
