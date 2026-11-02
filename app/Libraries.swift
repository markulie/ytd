// yt-dlp, ffmpeg and Deno: where they live, which version is installed,
// which is newest, and fetching one. Every download is checked against its
// published SHA-256, and ffmpeg and Deno also against their publisher's
// Developer ID signature: the checksum proves the file wasn't damaged, the
// signature proves who built it. Only stable releases are ever taken
// (Deno: its LTS line).
import CryptoKit
import Foundation

struct LibraryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Libraries {
    static let names = ["yt-dlp", "ffmpeg", "deno"]

    /// ~/Library/Application Support/YTD — an app must not modify its own
    /// bundle, and macOS may run a freshly downloaded app from a read-only copy.
    private static let supportFolder = FileManager.default.urls(for: .applicationSupportDirectory,
                                                                in: .userDomainMask)[0]
    static let folder = supportFolder.appendingPathComponent("YTD", isDirectory: true)
    /// where versions called Web Video Downloader kept them
    private static let oldFolder = supportFolder.appendingPathComponent("Web Video Downloader", isDirectory: true)
    private static let bin = folder.appendingPathComponent("bin", isDirectory: true)

    // yt-dlp's "onedir" zip (a universal2 build) unpacks once, so it starts in
    // ~0.3s; the single-file build re-extracts itself on every run.
    static let ytdlp = bin.appendingPathComponent("yt-dlp/yt-dlp_macos")
    private static let ytdlpReleases = "https://github.com/yt-dlp/yt-dlp/releases"
    private static let ytdlpZip = "yt-dlp_macos.zip"

    // martin-riedl.de: static builds behind a stable "latest" redirect, one
    // bare binary per zip, each with a .sha256 beside it.
    static let ffmpegFolder = bin.appendingPathComponent("ffmpeg", isDirectory: true)
    private static let ffmpegDownloads = "https://ffmpeg.martin-riedl.de/download/macos/\(arm ? "arm64" : "amd64")"
    private static let ffmpegLatest = "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arm ? "arm64" : "amd64")/release/ffmpeg.zip"
    private static let ffmpegSigner = #"anchor apple generic and certificate leaf[subject.OU] = "KU3N25YGLU""#

    // Deno: YouTube hides some formats behind a JavaScript challenge, which
    // yt-dlp can only solve with a JS runtime. Deno's LTS pointer is followed.
    static let deno = bin.appendingPathComponent("deno/deno")
    private static let denoTriple = arm ? "aarch64-apple-darwin" : "x86_64-apple-darwin"
    private static let denoDownloads = "https://github.com/denoland/deno/releases/download"
    private static let denoLatest = "https://dl.deno.land/release-lts-latest.txt"
    private static let denoSigner = #"anchor apple generic and certificate leaf[subject.OU] = "2H4KBF436B""#

    // which upstream build is unpacked, written beside ffmpeg and deno
    private static let stampName = ".version"

    /// Apple silicon, even when this app itself runs under Rosetta.
    private static let arm: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    private static let fileManager = FileManager.default
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    // MARK: Versions

    /// What's installed: yt-dlp's version, ffmpeg's build id, Deno's version.
    static func installed(_ name: String) async -> String? {
        switch name {
        case "yt-dlp":
            guard fileManager.isExecutableFile(atPath: ytdlp.path) else { return nil }
            let result = await run(ytdlp, ["--version"])  // also proves it runs
            let version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.status == 0 && !version.isEmpty ? version : nil
        case "ffmpeg":
            return stamp(in: ffmpegFolder, binary: "ffmpeg")
        case "deno":
            return stamp(in: deno.deletingLastPathComponent(), binary: "deno")
        default:
            return nil
        }
    }

    /// The newest stable release, in the same form as `installed`.
    static func latest(_ name: String) async -> String? {
        switch name {
        case "yt-dlp": return await resolve("\(ytdlpReleases)/latest").flatMap(Release.ytdlpVersion)
        case "ffmpeg": return await resolve(ffmpegLatest).flatMap(Release.ffmpegBuild)
        case "deno": return await text(denoLatest).flatMap(Release.denoVersion)
        default: return nil
        }
    }

    /// How a version is shown: ffmpeg's build id "1789931890_9.0.2" is "9.0.2".
    static func display(_ name: String, _ version: String?) -> String? {
        guard let version = version else { return nil }
        return name == "ffmpeg" ? Release.ffmpegVersion(ofBuild: version) : version
    }

    // MARK: Installing

    /// Download, verify and swap in `version` of a library. Everything is
    /// unpacked into a scratch folder first, so a failure can't break the
    /// copy that's already there. `progress` gets 0...1, or nil if unknown.
    static func install(_ name: String, version: String,
                        progress: @escaping @Sendable (Double?) -> Void) async throws {
        let staging = bin.appendingPathComponent("\(name).new", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            switch name {
            case "yt-dlp":
                let base = "\(ytdlpReleases)/download/\(version)"
                let sums = await text("\(base)/SHA2-256SUMS")
                try await grab("\(base)/\(ytdlpZip)", sha256: sums.flatMap { Release.checksum(in: $0, for: ytdlpZip) },
                               into: staging, progress: progress)
                let binary = staging.appendingPathComponent(ytdlp.lastPathComponent)
                guard fileManager.fileExists(atPath: binary.path) else {
                    throw LibraryError("The yt-dlp download didn't contain yt-dlp.")
                }
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                try swapIn(staging, as: ytdlp.deletingLastPathComponent())

            case "ffmpeg":
                // ffmpeg and ffprobe from the one build, each filling half the bar
                for (index, tool) in ["ffmpeg", "ffprobe"].enumerated() {
                    let url = "\(ffmpegDownloads)/\(version)/\(tool).zip"
                    let sums = await text(url + ".sha256")
                    try await grab(url, sha256: sums.flatMap { Release.checksum(in: $0, for: "\(tool).zip") },
                                   into: staging) { part in progress(part.map { (Double(index) + $0) / 2 }) }
                    try await requireSignature(staging.appendingPathComponent(tool), ffmpegSigner)
                }
                try version.write(to: staging.appendingPathComponent(stampName), atomically: true, encoding: .utf8)
                try swapIn(staging, as: ffmpegFolder)

            case "deno":
                let url = "\(denoDownloads)/v\(version)/deno-\(denoTriple).zip"
                let sums = await text(url + ".sha256sum")
                try await grab(url, sha256: sums.flatMap { Release.checksum(in: $0, for: "deno-\(denoTriple).zip") },
                               into: staging, progress: progress)
                try await requireSignature(staging.appendingPathComponent("deno"), denoSigner)
                try version.write(to: staging.appendingPathComponent(stampName), atomically: true, encoding: .utf8)
                try swapIn(staging, as: deno.deletingLastPathComponent())

            default:
                throw LibraryError("Unknown library \(name).")
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Tidy up after earlier versions: for a while the app was called Web
    /// Video Downloader, so its libraries move over rather than being
    /// downloaded again, and it used to run on a Python it downloaded, which
    /// is no longer used.
    static func migrateOldFiles() {
        if fileManager.fileExists(atPath: oldFolder.path) && !fileManager.fileExists(atPath: folder.path) {
            try? fileManager.moveItem(at: oldFolder, to: folder)
        }
        for leftover in ["python", "python.new"] {
            try? fileManager.removeItem(at: folder.appendingPathComponent(leftover))
        }
    }

    // MARK: Helpers

    private static func stamp(in folder: URL, binary: String) -> String? {
        guard fileManager.fileExists(atPath: folder.appendingPathComponent(binary).path),
              let text = (try? String(contentsOf: folder.appendingPathComponent(stampName), encoding: .utf8))
                ?? (try? String(contentsOf: folder.appendingPathComponent(".build"), encoding: .utf8))  // older versions
        else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    private static func swapIn(_ staging: URL, as target: URL) throws {
        try? fileManager.removeItem(at: target)
        try fileManager.moveItem(at: staging, to: target)
    }

    /// Download a zip, check it against its published hash, unpack it.
    private static func grab(_ url: String, sha256 expected: String?, into folder: URL,
                             progress: @escaping @Sendable (Double?) -> Void) async throws {
        let name = (url as NSString).lastPathComponent
        guard let expected = expected else {
            throw LibraryError("Couldn't get the published checksum for \(name).")
        }
        let archive = folder.appendingPathComponent("download.zip")
        try await FileDownload.fetch(URL(string: url)!, to: archive, progress: progress)
        guard try sha256(of: archive) == expected else {
            throw LibraryError("\(name) doesn't match its published checksum — not using it.")
        }
        // ditto rather than Foundation: it keeps permissions as zipped
        guard await run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, folder.path]).status == 0 else {
            throw LibraryError("Couldn't unpack \(name).")
        }
        try fileManager.removeItem(at: archive)
    }

    private static func requireSignature(_ binary: URL, _ requirement: String) async throws {
        guard fileManager.fileExists(atPath: binary.path) else {
            throw LibraryError("The download didn't contain \(binary.lastPathComponent).")
        }
        let result = await run(URL(fileURLWithPath: "/usr/bin/codesign"),
                               ["--verify", "--strict", "-R", "=" + requirement, binary.path])
        guard result.status == 0 else {
            throw LibraryError("The downloaded \(binary.lastPathComponent) isn't signed by its publisher — not using it.")
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func text(_ url: String) async -> String? {
        guard let reply = try? await session.data(from: URL(string: url)!),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: reply.0, as: UTF8.self)
    }

    /// Where a "latest" link currently redirects to. Asks for one byte only.
    private static func resolve(_ url: String) async -> String? {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let reply = try? await session.data(for: request),
              let response = reply.1 as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { return nil }
        return response.url?.absoluteString
    }

    /// Run a short command and collect what it prints.
    private static func run(_ executable: URL, _ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: output, as: UTF8.self)))
            }
        }
    }
}

/// One file over URLSession, reporting progress as it arrives.
private final class FileDownload: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL,
                      progress: @escaping @Sendable (Double?) -> Void) async throws {
        let download = FileDownload(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            download.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        progress(expected > 0 ? Double(written) / Double(expected) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // the temporary file is deleted once this returns, so move it now
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            failure = LibraryError("Download failed (HTTP \(status)) — check your connection and try again.")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? failure {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
