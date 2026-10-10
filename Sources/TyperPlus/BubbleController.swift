import AppKit
import SwiftUI
import Combine

// NOTE: the default-position helper (`BubbleAnchor`), `BubbleLayout`, and the SwiftUI
// `BubbleView` all live in UI/BubbleView.swift. This file owns only the host NSPanel +
// position persistence and the bridge into the AppController typing path.

// MARK: - The panel

/// Borderless, always-on-top panel that can become key (so its paste field accepts
/// typing + ⌘V) yet does NOT activate the app or pull it off other Spaces. Mirrors the
/// CountdownHUD window config, but interactive and draggable.
private final class BubblePanel: NSPanel {
    /// False while a run is typing: a key panel receives the injected keystrokes even though
    /// it is non-activating, so the bubble must never hold key focus during a run.
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Owns the floating bubble panel and hosts the existing SwiftUI `BubbleView` (driven by
/// the shared `AppModel`, so the bubble's mode / typing state stay in lock-step with the
/// menu + main window). Created and retained by AppController.
///
/// Show/hide is idempotent; position (a free-dragged point, default bottom-right) is persisted in Settings and restored on show.
///
/// SAFETY: the paste field can hold key focus while you compose, but the moment you type,
/// `BubbleView` → `AppModel.typeText` → `AppController.beginTyping` runs, which calls
/// `NSApp.deactivate()` and then the countdown — so by the time keys are injected the
/// bubble is NOT the focused field, and the kill switch ignores our own injected keys by
/// source PID. The bubble can therefore never type into itself.
final class BubbleController: NSObject, NSWindowDelegate {

    private let model: AppModel
    private var panel: BubblePanel?
    private var typingSub: AnyCancellable?

    /// Minimized to the small sliver (only + and Type clipboard).
    private var collapsed: Bool = Settings.shared.bubbleCollapsed

    /// Inline text box shown (compact, auto-growing); `panelHeight` tracks its content.
    private var textBoxOpen: Bool = Settings.shared.bubbleTextBoxOpen
    private var panelHeight: CGFloat = BubbleLayout.height

    private static let size = NSSize(width: BubbleLayout.width, height: BubbleLayout.height)
    private static let collapsedSize = NSSize(width: BubbleLayout.collapsedWidth, height: BubbleLayout.collapsedHeight)

    init(model: AppModel) {
        self.model = model
        super.init()
        // While typing: drop key focus and refuse it, so a click can't put the caret in the
        // bubble's text box and swallow the injected keys. Restored when the run ends.
        typingSub = model.$isTyping.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] typing in
            guard let panel = self?.panel else { return }
            panel.allowsKey = !typing
            if typing {
                panel.makeFirstResponder(nil)
                if panel.isKeyWindow { panel.resignKey() }
            }
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Hotkey (⌘⌥B): flip visibility, preserving collapsed/expanded state.
    func toggle() { isVisible ? hide() : show() }

    /// Explicit "Open pop-out" button: ALWAYS bring up the full bubble, on-screen and in
    /// front (never the silent toggle-off, never a stale off-screen spot).
    func present() {
        if collapsed { collapsed = false; Settings.shared.bubbleCollapsed = false }
        show()
    }

    func show() {
        let panel = ensurePanel()
        rehostView()
        applyLayout(to: panel)          // size + clamp on-screen
        panel.orderFrontRegardless()    // show without activating / leaving the current Space
        if panel.allowsKey { panel.makeKey() }
        Settings.shared.bubbleVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        Settings.shared.bubbleVisible = false
    }

    /// Minimize to / restore from the bottom-right sliver.
    func setCollapsed(_ c: Bool) {
        collapsed = c
        Settings.shared.bubbleCollapsed = c
        rehostView()
        if let panel = panel { applyLayout(to: panel) }
    }

    func setTextBoxOpen(_ open: Bool) {
        textBoxOpen = open
        Settings.shared.bubbleTextBoxOpen = open
        if !open { panelHeight = BubbleLayout.height }
        rehostView()
        if let panel = panel { applyLayout(to: panel, keepingTop: true) }
    }

    /// The text box grew/shrank: resize the panel, keeping its top edge fixed.
    private func contentHeightChanged(_ h: CGFloat) {
        guard textBoxOpen, !collapsed, abs(h - panelHeight) > 0.5 else { return }
        panelHeight = h
        if let panel = panel, panel.isVisible { applyLayout(to: panel, keepingTop: true) }
    }

    // MARK: - Panel construction

    private func ensurePanel() -> BubblePanel {
        if let panel = panel { return panel }

        let panel = BubblePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                       // the SwiftUI card draws its own elevation
        panel.isMovableByWindowBackground = true      // drag from anywhere on the bubble body
        panel.hidesOnDeactivate = false
        panel.delegate = self                          // windowDidMove → persist the new spot
        panel.allowsKey = !model.isTyping

        self.panel = panel
        rehostView()
        return panel
    }

    /// (Re)install the SwiftUI content with the current `anchor` pushed in. Cheap; called
    /// whenever the anchor changes so the pin control re-renders.
    private func rehostView() {
        guard let panel = panel else { return }
        let root = BubbleView(
            onClose:    { [weak self] in self?.hide() },
            onMinimize: { [weak self] in self?.setCollapsed(true) },
            onExpand:   { [weak self] in self?.setCollapsed(false) },
            collapsed:  collapsed,
            textBoxOpen: textBoxOpen,
            onToggleTextBox: { [weak self] in
                guard let self = self else { return }
                self.setTextBoxOpen(!self.textBoxOpen)
            },
            onHeightChange: { [weak self] h in
                // Defer: this fires during a SwiftUI layout pass.
                DispatchQueue.main.async { self?.contentHeightChanged(h) }
            })
            .environmentObject(model)
        // FirstMouseHostingView: the bubble is the user's primary surface and floats above
        // other apps without taking focus, so a click on its Type/Cancel button would
        // otherwise only make the panel key (needing a 2nd click). acceptsFirstMouse fires it
        // on the first click.
        panel.contentView = FirstMouseHostingView(rootView: root)
    }

    // MARK: - Drag (free movement) + persistence
    //
    // The panel is movable-by-window-background (grab it anywhere, AppKit drives the drag).
    // No snapping — it stays exactly where you drop it, in either size. We just remember the
    // dropped point; on show we clamp it on-screen so the bubble can never open off-screen.

    private var suppressMoveSave = false

    /// Run a programmatic reposition without it being mistaken for a user drag.
    private func moveProgrammatically(_ block: () -> Void) {
        suppressMoveSave = true
        block()
        suppressMoveSave = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !suppressMoveSave, let panel = panel, panel.isVisible else { return }
        Settings.shared.setBubblePoint(panel.frame.origin)   // free — exactly where you drop it
    }

    // MARK: - Positioning

    /// Size the panel for the current state and place it at the saved free point, clamped
    /// fully on-screen (so a stale/edge point can never make "Open pop-out" appear to fail).
    private func applyLayout(to panel: NSPanel, keepingTop: Bool = false) {
        let size = collapsed ? Self.collapsedSize
                 : NSSize(width: BubbleLayout.width, height: textBoxOpen ? panelHeight : BubbleLayout.height)
        moveProgrammatically {
            var origin = visibleOrigin(panel, for: size)
            if keepingTop, panel.isVisible {
                // Grow/shrink downward from the current top edge, then clamp on-screen.
                origin = NSPoint(x: panel.frame.origin.x, y: panel.frame.maxY - size.height)
                if let vf = (NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main)?.visibleFrame {
                    origin.y = min(max(origin.y, vf.minY + 6), vf.maxY - size.height - 6)
                }
            }
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }

    private func visibleOrigin(_ panel: NSPanel, for size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return Settings.shared.bubblePoint ?? panel.frame.origin }
        var o = Settings.shared.bubblePoint ?? BubbleAnchor.defaultOrigin(in: vf, size: size)
        o.x = min(max(o.x, vf.minX + 6), vf.maxX - size.width - 6)
        o.y = min(max(o.y, vf.minY + 6), vf.maxY - size.height - 6)
        return o
    }
}
