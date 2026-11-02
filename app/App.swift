// YTD — paste a YouTube link, it downloads. A small white window in front
// of yt-dlp, which the app keeps up to date along with ffmpeg and Deno.
//   Core.swift       pure logic: qualities, links, options, yt-dlp's output
//   Libraries.swift  fetching, verifying and updating yt-dlp, ffmpeg, Deno
//   Model.swift      the app's state, and running yt-dlp
//   Views.swift      the window's contents
import AppKit
import SwiftUI
@main
struct YTDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI's own windows always keep a title bar, so the window is an
        // AppKit one made by AppDelegate; this scene only supplies the menus.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates") { appDelegate.model.check() }
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    private var window: PanelWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = PanelWindow(content: ContentView().environmentObject(model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// A plain white window: the title bar shows the app's name and version but
/// no separator, so it reads as part of the same white surface. The window is
/// always exactly as big as its content, and drags by any empty spot.
final class PanelWindow: NSWindow {
    init<Content: View>(content: Content) {
        // not .resizable: the content decides the size, so zoom stays greyed out
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                   styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleDisplayName"] as? String ?? "YTD"
        title = [name, info["CFBundleShortVersionString"] as? String].compactMap { $0 }.joined(separator: " ")
        titlebarAppearsTransparent = true  // the title bar shows the white background
        titlebarSeparatorStyle = .none
        backgroundColor = .white
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .aqua)  // stays white in dark mode too
        let host = NSHostingView(rootView: content.fixedSize())
        host.sizingOptions = [.minSize, .maxSize]  // window size = content size, always
        contentView = host
    }
}

/// The white surface behind everything; dragging it moves the window.
struct PanelBackground: NSViewRepresentable {
    final class Surface: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> NSView {
        let view = Surface()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

