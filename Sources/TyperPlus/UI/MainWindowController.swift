import AppKit
import SwiftUI

/// Owns the SwiftUI main window. Created and retained by AppController. The window is
/// built once and reused (never released on close), so the menu bar / hotkey keep the
/// app alive in the background and a Dock-click can re-show it instantly.
final class MainWindowController {

    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func showWindow() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = RootView().environmentObject(model).ignoresSafeArea()
        let host = FirstMouseHostingController(rootView: root)
        // Don't let SwiftUI's measured content size drive a minimum that overrides the
        // window's own `minSize` below — otherwise the window resists shrinking and "snaps
        // back" to a larger size. The window stays freely resizable down to `minSize`.
        if #available(macOS 13.0, *) { host.sizingOptions = [] }

        let defaultSize = NSSize(width: 1120, height: 740)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        win.contentViewController = host
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.title = "Typer+"
        win.isReleasedWhenClosed = false          // mandatory: reused on reopen
        win.minSize = NSSize(width: 720, height: 560)
        win.backgroundColor = NSColor(Theme.cream)   // single source of truth (DesignSystem)

        // Assigning `contentViewController` above silently shrinks the window to whatever
        // (near-zero) size the SwiftUI hosting view reports before its first layout pass —
        // re-assert the real size before centering.
        win.setContentSize(defaultSize)
        win.center()

        // `setFrameAutosaveName` immediately restores whatever frame string was last
        // persisted, clobbering the good frame just set above. A corrupted/degenerate saved
        // frame (this shipped once as "719 676 1 1", collapsed from the SwiftUI hosting
        // view's pre-layout size, above) can NEVER come from legitimate interactive
        // resizing — the user can't drag a window below `minSize` — so any saved size under
        // `minSize` is definitely this bug, not a real preference. NSWindow's own restore
        // path clamps such a frame UP to exactly `minSize` instead of leaving it at its
        // degenerate saved size, so checking the frame *after* restoring can miss it (720 is
        // not `< 720`) — the corrupted value must be purged from the raw saved string BEFORE
        // `setFrameAutosaveName` ever gets to restore it.
        let autosaveKey = "NSWindow Frame TyperPlusMain"
        if let saved = UserDefaults.standard.string(forKey: autosaveKey) {
            let parts = saved.split(separator: " ").compactMap { Double($0) }
            if parts.count >= 4, (parts[2] < Double(win.minSize.width) || parts[3] < Double(win.minSize.height)) {
                UserDefaults.standard.removeObject(forKey: autosaveKey)
            }
        }
        win.setFrameAutosaveName("TyperPlusMain")

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool { window?.isVisible ?? false }
}

/// Hosting view that accepts the FIRST mouse click even when the window is in the
/// background. During a run Typer+ is deactivated (so the target app keeps focus), so the
/// main window is a background window — without this, clicking the on-screen Stop button
/// would be consumed just to re-activate the app (the button wouldn't fire until a 2nd
/// click, and the activation would steal focus mid-run). With it, the Stop button halts
/// the run on the very first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() { view = FirstMouseHostingView(rootView: rootView) }
}
