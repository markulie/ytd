// The app's state: the link field, options, the download list, and the
// three libraries. Downloads run yt-dlp directly, a few side by side. A
// library job (setting up, checking, updating) runs one at a time, and never
// while something is downloading: yt-dlp mustn't be replaced under itself.
import AppKit
import Foundation

@MainActor
final class Model: ObservableObject {
    enum LibraryJob: Equatable { case settingUp, checking, updating(String) }

    @Published var url = "" {
        didSet { if url != oldValue { note = nil } }
    }
    @Published var quality: Quality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    @Published var options = Options.load() {
        didSet { options.save() }
    }
    /// The window floats above other apps' windows: on unless turned off.
    @Published var alwaysOnTop = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true {
        didSet { UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop") }
    }
    /// The larger layout the green button switches to: wider, with a taller list.
    @Published var large = UserDefaults.standard.bool(forKey: "large") {
        didSet { UserDefaults.standard.set(large, forKey: "large") }
    }
    // a clip applies to the links added next only, so it isn't remembered
    @Published var clipStart = ""
    @Published var clipEnd = ""

    @Published private(set) var items: [Item] = Model.loadItems()
    @Published private(set) var listRunning = false
    @Published private(set) var note: String?  // a short word on the last action

    @Published private(set) var libraryJob: LibraryJob? = .settingUp
    @Published private(set) var librariesReady = false
    @Published private(set) var status = "Getting ready…"
    @Published private(set) var progress: Double?  // nil while busy: no figure yet
    @Published private(set) var errorText: String?
    @Published private(set) var tools = Dictionary(uniqueKeysWithValues: Libraries.names.map { ($0, Tool()) })

    private var runners: [Item.ID: Runner] = [:]
    private var stopping: Set<Item.ID> = []
    private var lastErrors: [Item.ID: String] = [:]
    private var lastChecked: Date?
    private var seenPasteboard = -1
    private var autoFilled: String?  // the link the app last put in the field
    private var clipboardWatch: Timer?

    var libraryBusy: Bool { libraryJob != nil }
    var downloading: Bool { !runners.isEmpty }
    var fieldValid: Bool { YouTube.onlyLinks(in: url) }
    var clip: String? { Clip.section(start: clipStart, end: clipEnd) }
    var choicesValid: Bool { clip != "" && options.languagesValid }
    var canAdd: Bool { fieldValid && choicesValid }
    var startable: Int { items.filter { $0.state == .waiting || $0.state == .stopped }.count }
    var canDownload: Bool { canAdd || (url.isEmpty && startable > 0) }
    var downloadTitle: String { url.isEmpty && startable > 1 ? "Download All" : "Download" }

    /// Hints about the field and options, or a word on the last action.
    /// (Library work shows in the libraries card instead.)
    var showsActivity: Bool {
        note != nil || (!url.isEmpty && !fieldValid) || clip == "" || !options.languagesValid
    }

    var isUpdating: Bool {
        if case .updating = libraryJob { return true }
        return false
    }

    init() {
        Self.migrateOldSettings()
        quality = Quality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .best
    }

    /// Settings saved while the app was called Web Video Downloader (bundle
    /// id local.web-video-downloader) are newer than any from before, so they
    /// win; the old copy is removed once moved, so this happens only once.
    private static func migrateOldSettings() {
        let oldDomain = "local.web-video-downloader"
        guard let old = UserDefaults.standard.persistentDomain(forName: oldDomain) else { return }
        for key in ["quality", "options", "list"] {
            if let value = old[key] {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        UserDefaults.standard.removePersistentDomain(forName: oldDomain)
    }

    func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
        // follow the clipboard while you're in another app and ytd can be seen
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateClipboardWatch() }
            }
        }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                           queue: .main) { [weak self] _ in
            // each download stops cleanly and resumes from its partial file
            // next time; the saved list already has it as downloading
            MainActor.assumeIsolated { self?.runners.values.forEach { $0.interrupt() } }
        }
        updateBadge()
        checkClipboard()
        setup()
    }

    private func becameActive() {
        checkClipboard()
        // look for new versions again once the last look is an hour old
        if !libraryBusy, !downloading, let last = lastChecked, last.timeIntervalSinceNow < -3600 {
            check()
        }
    }

    // MARK: The field

    /// Fill the field from the clipboard, but only when all it holds is one
    /// YouTube link, only once per copy (so a link you cleared doesn't keep
    /// coming back), and never over something typed in the field.
    func checkClipboard() {
        let board = NSPasteboard.general
        // macOS counts clipboard changes: comparing that number reads nothing
        guard board.changeCount != seenPasteboard else { return }
        seenPasteboard = board.changeCount
        guard ClipboardFill.mayReplace(field: url, autoFilled: autoFilled) else { return }
        if #available(macOS 15.4, *) {
            // ask macOS whether it's a web link first, so nothing else that's
            // copied (a password, a message) is ever read
            Task {
                let link: PartialKeyPath<NSPasteboard.DetectedValues> = \.probableWebURL
                guard let found = try? await board.detectedPatterns(for: [link]), found.contains(link) else { return }
                fill(from: board)
            }
        } else {
            fill(from: board)
        }
    }

    private func fill(from board: NSPasteboard) {
        guard ClipboardFill.mayReplace(field: url, autoFilled: autoFilled),
              let text = board.string(forType: .string), let link = YouTube.link(in: text) else { return }
        url = link
        autoFilled = link
    }

    /// There's no notification for a copy, so while it can matter — you're in
    /// another app and ytd's window can be seen — the change count is looked
    /// at once a second. The rest of the time nothing runs at all.
    private func updateClipboardWatch() {
        let seen = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        if !NSApp.isActive && seen {
            guard clipboardWatch == nil else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkClipboard() }
            }
            timer.tolerance = 0.5  // lets macOS run it alongside wake-ups it makes anyway
            RunLoop.main.add(timer, forMode: .common)
            clipboardWatch = timer
        } else {
            clipboardWatch?.invalidate()
            clipboardWatch = nil
        }
    }

    /// The Paste button: one link goes into the field; several (a list
    /// copied from notes or a chat) go straight into the download list.
    func paste() {
        seenPasteboard = NSPasteboard.general.changeCount
        let links = YouTube.links(in: NSPasteboard.general.string(forType: .string) ?? "")
        switch links.count {
        case 0: note = "There's no YouTube link on the clipboard."
        case 1:
            url = links[0]
            autoFilled = links[0]  // pasted, not typed: a later copy may replace it
        default: add(links)
        }
    }

    /// The Add button: the field's links go into the list, for later.
    func addFromField() {
        guard canAdd else { return }
        let links = YouTube.links(in: url)
        url = ""
        add(links)
    }

    /// The Download button: the field's links, if any, and everything
    /// waiting or stopped in the list.
    func downloadAll() {
        guard canDownload else { return }
        if canAdd {
            let links = YouTube.links(in: url)
            url = ""
            add(links, quietly: true)
        }
        for index in items.indices where items[index].state == .stopped {
            items[index].state = .waiting
        }
        listRunning = true
        pump()
    }

    private func add(_ links: [String], quietly: Bool = false) {
        var added = 0
        for link in links {
            let item = Item(link: link, quality: quality, options: options, clip: clip)
            let queued = items.contains { $0.sameDownload(as: item) && ![.done, .failed].contains($0.state) }
            if !queued {
                items.append(item)
                added += 1
            }
        }
        clipStart = ""
        clipEnd = ""
        saveItems()
        let skipped = links.count - added
        if !quietly || skipped > 0 {
            note = [added == 0 ? nil : added == 1 ? "Added to the list." : "Added \(added) links to the list.",
                    skipped == 0 ? nil : skipped == 1 ? "One was already in it." : "\(skipped) were already in it."]
                .compactMap { $0 }.joined(separator: " ")
        }
        pump()  // joins in at once if the list is already downloading
    }

    // MARK: The list

    func stopAll() {
        listRunning = false
        runners.keys.forEach(stop)
    }

    func stop(_ id: Item.ID) {
        stopping.insert(id)
        runners[id]?.interrupt()
    }

    /// Retry a failed one, or carry on with a stopped one.
    func resume(_ id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .waiting
        items[index].error = nil
        listRunning = true
        pump()
    }

    func remove(_ id: Item.ID) {
        guard runners[id] == nil else { return }
        items.removeAll { $0.id == id }
        saveItems()
    }

    func clearFinished() {
        items.removeAll { $0.state == .done }
        saveItems()
    }

    func showInFinder(_ item: Item) {
        if let file = item.file, FileManager.default.fileExists(atPath: file) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.options.folder, isDirectory: true))
        }
    }

    /// Start as many waiting downloads as may run at once.
    private func pump() {
        guard listRunning, librariesReady, !libraryBusy else { return }
        for id in Queue.toStart(items, atOnce: options.atOnce) {
            launch(id)
        }
        if runners.isEmpty {  // nothing left to do
            listRunning = false
            if let app = NSApp, !app.isActive, items.contains(where: { $0.state == .done }) {
                app.requestUserAttention(.informationalRequest)  // one bounce in the Dock
            }
        }
        updateBadge()
    }

    private func launch(_ id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        try? FileManager.default.createDirectory(atPath: item.options.folder, withIntermediateDirectories: true)
        let arguments = ["--ffmpeg-location", Libraries.ffmpegFolder.path,  // ours, never a system one
                         "--js-runtimes", "deno:\(Libraries.deno.path)"]
            + item.arguments
            + YtdlpLine.eventArguments
            + ["--", item.link]  // after --, a link can never be read as an option
        items[index].state = .downloading
        items[index].progress = nil
        items[index].error = nil

        let runner = Runner(executable: Libraries.ytdlp, arguments: arguments,
                            onLine: { [weak self] in self?.handle(YtdlpLine($0), for: id) },
                            onExit: { [weak self] in self?.finished(id, code: $0) })
        runners[id] = runner
        do {
            try runner.start()
        } catch {
            runners[id] = nil
            items[index].state = .failed
            items[index].error = error.localizedDescription
        }
        saveItems()
    }

    private func handle(_ line: YtdlpLine, for id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch line {
        case let .progress(percent, audio):
            // video and audio come one after the other, each 0-100%
            items[index].progress = percent / 100
            items[index].audio = audio
        case let .title(title):
            items[index].title = title
            saveItems()
        case let .details(resolution, size):
            items[index].resolution = resolution
            items[index].size = size
            saveItems()
        case let .file(path): items[index].file = path
        case let .error(message): lastErrors[id] = message
        case .message, .ignored: break
        }
    }

    private func finished(_ id: Item.ID, code: Int32) {
        runners[id] = nil
        let stopped = stopping.remove(id) != nil
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].progress = nil
            if stopped {
                items[index].state = .stopped
            } else if code == 0 {
                items[index].state = .done
            } else {
                items[index].state = .failed
                items[index].error = lastErrors[id] ?? "yt-dlp stopped with exit code \(code)."
            }
        }
        lastErrors[id] = nil
        saveItems()
        pump()
    }

    /// The Dock icon shows how many are left while the list downloads.
    private func updateBadge() {
        let left = items.filter { $0.state == .waiting || $0.state == .downloading }.count
        NSApp?.dockTile.badgeLabel = listRunning && left > 0 ? "\(left)" : nil
    }

    // Finished ones aren't kept: the file in Finder is the record of those.
    private static func loadItems() -> [Item] {
        guard let data = UserDefaults.standard.data(forKey: "list"),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.map { $0.restored() }
    }

    private func saveItems() {
        let kept = items.filter { $0.state != .done }
        UserDefaults.standard.set(try? JSONEncoder().encode(kept), forKey: "list")
        updateBadge()
    }

    // MARK: Libraries

    /// Fetch whichever libraries are missing, then see which are current.
    func setup() {
        beginLibraryJob(.settingUp, status: "Getting ready…")
        Task {
            Libraries.migrateOldFiles()
            do {
                for name in Libraries.names {
                    if await Libraries.installed(name) == nil {
                        try await install(name)
                    }
                }
                await refreshTools()
                endLibraryJob()
            } catch {
                endLibraryJob(failure: error.localizedDescription)
            }
        }
    }

    func check() {
        guard !libraryBusy else { return }
        beginLibraryJob(.checking, status: "")
        Task {
            await refreshTools()
            endLibraryJob()
        }
    }

    var updatesAvailable: [String] {
        Libraries.names.filter { tools[$0].map { [.update, .missing].contains($0.state) } ?? false }
    }

    func update(_ name: String) {
        update([name])
    }

    /// Every library that's behind or missing, one after another.
    func updateAll() {
        update(updatesAvailable)
    }

    private func update(_ names: [String]) {
        guard !libraryBusy, !downloading, let first = names.first else { return }
        beginLibraryJob(.updating(first), status: "")
        Task {
            do {
                for name in names {
                    libraryJob = .updating(name)
                    status = "Checking \(name)…"
                    if await Libraries.installed(name) != (await Libraries.latest(name)) {
                        try await install(name)
                    }
                    tools[name] = await Self.lookUp(name)
                }
                endLibraryJob()
            } catch {
                endLibraryJob(failure: error.localizedDescription)
            }
        }
    }

    private func beginLibraryJob(_ job: LibraryJob, status: String) {
        libraryJob = job
        self.status = status
        progress = nil
        errorText = nil
    }

    /// Downloads can start once every library is in place.
    private func endLibraryJob(failure: String? = nil) {
        libraryJob = nil
        status = ""
        progress = nil
        errorText = failure
        librariesReady = Libraries.names.allSatisfy { tools[$0]?.current != nil }
        pump()
    }

    private func install(_ name: String) async throws {
        guard let version = await Libraries.latest(name) else {
            throw LibraryError("Couldn't reach the server to download \(name) — check your connection.")
        }
        status = "Downloading \(name) \(Libraries.display(name, version) ?? version)…"
        progress = nil
        try await Libraries.install(name, version: version) { [weak self] value in
            DispatchQueue.main.async { self?.progress = value }
        }
    }

    private func refreshTools() async {
        await withTaskGroup(of: (String, Tool).self) { group in
            for name in Libraries.names {
                group.addTask { (name, await Self.lookUp(name)) }
            }
            for await (name, tool) in group {
                tools[name] = tool
            }
        }
        lastChecked = Date()
    }

    nonisolated private static func lookUp(_ name: String) async -> Tool {
        async let installed = Libraries.installed(name)
        async let latest = Libraries.latest(name)
        let (have, newest) = await (installed, latest)
        var shown = Libraries.display(name, newest)
        if let have = have, let newest = newest, have != newest, Libraries.display(name, have) == shown {
            shown? += " (new build)"  // same version number, rebuilt upstream
        }
        return Tool(state: Tool.state(installed: have, latest: newest),
                    current: Libraries.display(name, have), latest: shown)
    }

    // MARK: Finder

    func openFolder() {
        try? FileManager.default.createDirectory(atPath: options.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: options.folder, isDirectory: true))
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: options.folder, isDirectory: true)
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let folder = panel.url {
            options.folder = folder.path
        }
    }
}

extension Options {
    static func load() -> Options {
        guard let data = UserDefaults.standard.data(forKey: "options"),
              let options = try? JSONDecoder().decode(Options.self, from: data) else { return Options() }
        return options
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "options")
    }
}

/// Runs yt-dlp and hands back its output a line at a time, on the main queue.
final class Runner {
    private let process = Process()
    private let pipe = Pipe()
    private let queue = DispatchQueue(label: "runner")
    private let onLine: @MainActor (String) -> Void
    private let onExit: @MainActor (Int32) -> Void
    private var buffer = Data()
    private var reachedEnd = false
    private var exitCode: Int32?

    init(executable: URL, arguments: [String],
         onLine: @escaping @MainActor (String) -> Void, onExit: @escaping @MainActor (Int32) -> Void) {
        self.onLine = onLine
        self.onExit = onExit
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // yt-dlp hands some downloads (clips, live streams) to ffmpeg, whose
        // own TLS library doesn't know where macOS keeps the trusted roots
        if environment["SSL_CERT_FILE"] == nil { environment["SSL_CERT_FILE"] = "/etc/ssl/cert.pem" }
        environment["PYTHONUNBUFFERED"] = "1"  // yt-dlp is Python inside: keep its lines coming
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
    }

    func start() throws {
        // Both handlers keep self alive until the run is over; they are
        // cleared at the end, which lets it go.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            self.queue.async { self.received(data, from: handle) }
        }
        process.terminationHandler = { process in
            self.queue.async {
                self.exitCode = process.terminationStatus
                self.finishIfDone()
            }
        }
        try process.run()
    }

    /// Ctrl+C: yt-dlp stops cleanly and keeps the .part file to resume from.
    func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    private func received(_ data: Data, from handle: FileHandle) {
        guard !reachedEnd else { return }
        if data.isEmpty {  // end of output
            handle.readabilityHandler = nil
            reachedEnd = true
            emit(buffer)
            buffer.removeAll()
            finishIfDone()
            return
        }
        buffer.append(data)
        while let end = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            emit(buffer[buffer.startIndex..<end])
            buffer.removeSubrange(buffer.startIndex...end)
        }
    }

    private func emit(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        let line = String(decoding: bytes, as: UTF8.self)
        DispatchQueue.main.async { self.onLine(line) }
    }

    // Wait for both the exit and the end of output, so no line comes late.
    private func finishIfDone() {
        guard reachedEnd, let code = exitCode else { return }
        process.terminationHandler = nil
        DispatchQueue.main.async { self.onExit(code) }
    }
}
