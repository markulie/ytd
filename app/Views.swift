// The window's contents: the link row, what's happening, the download list,
// the three libraries, and the options popover.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: Model
    @State private var showOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The link gets the whole width to itself, and the field grows to
            // a few lines rather than cutting off a long link or several.
            TextField("YouTube link — or several", text: $model.url, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit(model.downloadAll)

            HStack(spacing: 6) {
                Button("Paste", action: model.paste)
                    .help("Paste from the clipboard. Several links go straight into the list.")
                Picker("Quality", selection: $model.quality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button { showOptions.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(model.options.changed || model.clip != nil ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Download options")
                .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                    OptionsView().environmentObject(model)
                }
                Spacer()
                Button("Add", action: model.addFromField)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canAdd)
                    .help("Add to the list, to download later (⌘↩)")
                Button(model.downloadTitle, action: model.downloadAll)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canDownload)
            }

            if model.showsActivity {
                ActivityView()
            }

            if !model.items.isEmpty {
                DownloadList()
            }

            LibrariesCard()
        }
        .frame(width: model.large ? 740 : 500)
        .padding([.horizontal, .bottom], 10)
        .padding(.top, 2)  // the title bar above already gives the top its space
        .background(PanelBackground())
    }
}

/// Hints about the field and options, and a word on the last action.
struct ActivityView: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.url.isEmpty && !model.fieldValid {
                Text("Only YouTube links, please — one, or several separated by spaces.")
                    .foregroundColor(.secondary)
            }
            if model.clip == "" {
                Text("Clip times look like 90, 1:30 or 1:02:03.").foregroundColor(.secondary)
            }
            if !model.options.languagesValid {
                Text("Subtitle languages look like en or en,de.").foregroundColor(.secondary)
            }
            if let note = model.note {
                Text(note).foregroundColor(.secondary)
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
    }
}

/// The links waiting, downloading and done; six rows tall at most (twelve
/// in the larger layout), then it scrolls.
struct DownloadList: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        let items = model.items
        let done = items.filter { $0.state == .done }.count
        let running = items.filter { $0.state == .downloading }.count
        let failed = items.filter { $0.state == .failed }.count
        VStack(spacing: 6) {
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { ItemRow(item: $0) }
                }
            }
            .frame(height: CGFloat(min(items.count, model.large ? 12 : 6)) * ItemRow.height)

            HStack(spacing: 8) {
                Text([
                    "\(done) of \(items.count) done",
                    running > 0 ? "\(running) downloading" : nil,
                    failed > 0 ? "\(failed) failed" : nil,
                ].compactMap { $0 }.joined(separator: " · "))
                .foregroundColor(.secondary)
                Spacer()
                if done > 0 {
                    Button("Clear Finished", action: model.clearFinished)
                }
                if model.listRunning {
                    Button("Stop All", action: model.stopAll)
                }
            }
            .font(.system(size: 11))
            .controlSize(.small)
        }
    }
}

/// One link in the list: what it is, how far along, and what can be done
/// with it now.
struct ItemRow: View {
    static let height: CGFloat = 38
    @EnvironmentObject private var model: Model
    let item: Item

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title ?? item.link)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .downloading {
                    if let progress = item.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                } else {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(item.state == .failed ? .red : .secondary)
                        .lineLimit(1)
                        .help(item.error ?? "")
                }
            }
            Spacer(minLength: 4)
            Text(badge)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)
            actions
        }
        .controlSize(.small)
        .frame(height: Self.height)
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .waiting: Image(systemName: "clock").foregroundColor(.secondary)
        case .downloading: Image(systemName: "arrow.down.circle").foregroundColor(.accentColor)
        case .stopped: Image(systemName: "pause.circle").foregroundColor(.secondary)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        }
    }

    private var detail: String {
        switch item.state {
        case .waiting: return "Waiting"
        case .downloading: return ""
        case .stopped: return "Stopped — picks up where it left off"
        case .done: return item.file.map { "Saved as \(($0 as NSString).lastPathComponent)" } ?? "Saved"
        case .failed: return item.error ?? "Failed"
        }
    }

    /// The resolution and estimated size once yt-dlp has picked (the quality
    /// asked for until then), the clip if any, and how far along it is.
    private var badge: String {
        var parts = [item.resolutionText]
        if let size = item.sizeText { parts.append(size) }
        if let clip = item.clip { parts.append("clip \(clip)") }
        if item.state == .downloading, let progress = item.progress {
            parts.append("\(item.audio ? "audio" : "video") \(Int(progress * 100))%")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            switch item.state {
            case .downloading:
                rowButton("stop.circle", "Stop") { model.stop(item.id) }
            case .stopped:
                rowButton("arrow.clockwise", "Carry on") { model.resume(item.id) }
            case .failed:
                rowButton("arrow.clockwise", "Try again") { model.resume(item.id) }
            case .done:
                rowButton("magnifyingglass", "Show in Finder") { model.showInFinder(item) }
            case .waiting:
                EmptyView()
            }
            if item.state != .downloading {
                rowButton("xmark", "Remove from the list") { model.remove(item.id) }
            }
        }
    }

    private func rowButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// The pin in the title bar: keeps the window above other apps' windows.
struct PinButton: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        Button { model.alwaysOnTop.toggle() } label: {
            Image(systemName: model.alwaysOnTop ? "pin.fill" : "pin")
                .rotationEffect(.degrees(45))
                .foregroundColor(model.alwaysOnTop ? .accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help(model.alwaysOnTop ? "On top of other windows — click to stop" : "Keep on top of other windows")
        .frame(width: 34, height: 28)
    }
}

/// yt-dlp, ffmpeg and Deno in a soft grey card. Its header sums them up in
/// a line; the rows fold away while there's nothing to do, and open by
/// themselves when an update is out, one is missing, or something fails.
struct LibrariesCard: View {
    @EnvironmentObject private var model: Model
    @AppStorage("librariesOpen") private var open = false

    private var needsYou: Bool {
        !model.updatesAvailable.isEmpty || model.errorText != nil || model.isUpdating
            || model.libraryJob == .settingUp || model.tools.values.contains { $0.state == .unknown }
    }

    var body: some View {
        let showRows = open || needsYou
        VStack(alignment: .leading, spacing: 0) {
            header(showRows: showRows)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

            if showRows {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach(Libraries.names, id: \.self) { LibraryRow(name: $0) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            if model.libraryJob == .settingUp || model.isUpdating || model.errorText != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if model.libraryJob == .settingUp || model.isUpdating {
                        if let progress = model.progress {
                            ProgressView(value: progress)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        if !model.status.isEmpty {
                            Text(model.status).foregroundColor(.secondary)
                        }
                    }
                    if let error = model.errorText {
                        Text(error)
                            .foregroundColor(.red)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 11))
                .controlSize(.small)
                .padding([.horizontal, .bottom], 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(white: 0.965)))
    }

    private func header(showRows: Bool) -> some View {
        HStack(spacing: 8) {
            Text("LIBRARIES")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            summary
            if model.updatesAvailable.count > 1 && !model.libraryBusy {
                Button("Update All", action: model.updateAll)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.downloading)
                    .help(model.downloading ? "Available once the downloads finish" : "")
            }
            Button(action: model.check) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .disabled(model.libraryBusy)
            .help("Check for updates now")
            if !needsYou {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(showRows ? 180 : 0))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !needsYou { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } }
        }
    }

    /// One line on all three: what needs doing, or that nothing does.
    @ViewBuilder private var summary: some View {
        let tools = model.tools.values
        let behind = model.updatesAvailable.count
        Group {
            if model.libraryJob == .settingUp {
                Text("Getting ready…").foregroundColor(.secondary)
            } else if case let .updating(name) = model.libraryJob {
                Text("Updating \(name)…").foregroundColor(.secondary)
            } else if model.libraryJob == .checking || tools.contains(where: { $0.state == .checking }) {
                Text("Checking…").foregroundColor(.secondary)
            } else if behind > 0 {
                Label(behind == 1 ? "1 update available" : "\(behind) updates available",
                      systemImage: "arrow.up.circle.fill")
                    .foregroundColor(.orange)
            } else if tools.contains(where: { $0.state == .unknown }) {
                Text("Couldn't check for updates").foregroundColor(.secondary)
            } else {
                Label("All up to date", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .font(.system(size: 11))
    }
}

/// One library: what it's for, the installed version, and whether it's the
/// newest stable release, with its own Update button when it isn't.
struct LibraryRow: View {
    @EnvironmentObject private var model: Model
    let name: String

    private static let roles = [
        "yt-dlp": "Downloads the video",
        "ffmpeg": "Merges, converts and cuts",
        "deno": "Unlocks all YouTube formats",
    ]

    var body: some View {
        let tool = model.tools[name] ?? Tool()
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(Self.roles[name] ?? "").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .frame(width: 170, alignment: .leading)
            Text(tool.current ?? "—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Spacer(minLength: 6)
            status(tool)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func status(_ tool: Tool) -> some View {
        // a library can't be replaced while yt-dlp is using it
        let blocked = model.libraryBusy || model.downloading
        if model.libraryJob == .updating(name) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Updating…")
            }
            .pill(.secondary)
        } else {
            switch tool.state {
            case .checking:
                Text("Checking…").pill(.secondary)
            case .latest:
                Label("Latest", systemImage: "checkmark").pill(.green)
            case .update:
                Button("Update to \(tool.latest ?? "newer")") { model.update(name) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(blocked)
                    .help(model.downloading ? "Available once the downloads finish" : "")
            case .unknown:
                Text("Couldn't check").pill(.secondary)
            case .missing:
                Button("Install") { model.update(name) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(blocked)
            }
        }
    }
}

extension View {
    /// A small tinted capsule, for a status that needs no action.
    func pill(_ tint: Color) -> some View {
        self
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

struct OptionsView: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            GridRow {
                Text("Save to").gridColumnAlignment(.trailing)
                HStack(spacing: 4) {
                    Text((model.options.folder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: 150, alignment: .leading)
                    Button("Change…", action: model.chooseFolder)
                    Button(action: model.openFolder) { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Open the folder")
                }
            }
            GridRow {
                Text("Subtitles")
                HStack(spacing: 6) {
                    Toggle("Embed, in", isOn: $model.options.subtitles)
                    TextField("en", text: $model.options.subtitleLanguages)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .disabled(!model.options.subtitles)
                        .help("Language codes, comma separated: en, de, ru…")
                }
            }
            GridRow {
                Text("Extras")
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Embed thumbnail, chapters & info", isOn: $model.options.embedInfo)
                    Toggle("Skip sponsors and intros (SponsorBlock)", isOn: $model.options.sponsorBlock)
                    Toggle("Whole playlist, into its own folder", isOn: $model.options.playlist)
                }
            }
            GridRow {
                Text("Video file")
                Picker("Video file", selection: $model.options.container) {
                    Text("Auto (mp4 when possible)").tag("auto")
                    Text("MP4").tag("mp4")
                    Text("MKV").tag("mkv")
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Audio file")
                Picker("Audio file", selection: $model.options.audioFormat) {
                    Text("Original (no re-encode)").tag("original")
                    Text("MP3").tag("mp3")
                    Text("M4A").tag("m4a")
                    Text("Opus").tag("opus")
                    Text("FLAC").tag("flac")
                    Text("WAV").tag("wav")
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Sign in")
                Picker("Sign in", selection: $model.options.cookiesFrom) {
                    Text("No").tag("none")
                    Divider()
                    Text("As in Safari").tag("safari")
                    Text("As in Chrome").tag("chrome")
                    Text("As in Firefox").tag("firefox")
                    Text("As in Brave").tag("brave")
                    Text("As in Edge").tag("edge")
                }
                .labelsHidden()
                .fixedSize()
                .help("For age-restricted or members-only videos: uses that browser's YouTube login")
            }
            GridRow {
                Text("Clip")
                HStack(spacing: 4) {
                    TextField("start", text: $model.clipStart)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)
                    Text("–")
                    TextField("end", text: $model.clipEnd)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)
                    Text("for the next links added").foregroundColor(.secondary)
                }
            }
            GridRow {
                Text("At once")
                Picker("At once", selection: $model.options.atOnce) {
                    ForEach(1...5, id: \.self) { Text($0 == 1 ? "1 download" : "\($0) downloads").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("How many links in the list download side by side")
            }
            if model.options.changed {
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    Button("Reset to Defaults") {
                        let folder = model.options.folder
                        model.options = Options()
                        model.options.folder = folder
                    }
                }
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .padding(12)
    }
}
