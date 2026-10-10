import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// Posts real OS-level keystrokes at the HID layer — never pastes, never touches
/// the clipboard. This is the injection primitive the whole tool rests on.
///
/// Detectability hygiene (RESEARCH.md §3.6 / §6):
///  • Source is `.hidSystemState` → events enter at the HID layer and read as
///    genuine hardware (the page sees `isTrusted: true`).
///  • `localEventsSuppressionInterval = 0` keeps real-input detection instant.
///  • Every event carries a real `mach_absolute_time()` timestamp (a posted event
///    defaults to timestamp 0 — a deterministic synthetic tell).
///  • Autorepeat is forced off; `eventSourceUserData` is left default (a constant
///    tag would be a readable self-fingerprint).
///  • One character per keyDown/keyUp pair (batching destroys per-key timing).
///
/// Text path: Unicode (`keyboardSetUnicodeString`, virtualKey 0) by default —
/// layout-independent and the path validated by the de-risk test. `preferKeycodePath`
/// flips to a US-QWERTY keycode+Shift path (set this if the de-risk test shows a
/// context needs a real `event.code`). Special keys (backspace/arrows/return/tab)
/// always use the keycode path.
final class KeyboardEngine {

    private let source: CGEventSource?

    /// Always attach the exact Unicode string (layout-independent glyph). When ON (default),
    /// characters with a real US-QWERTY key ALSO carry that key's virtual keycode; only chars
    /// with no US key (accents, smart quotes, emoji…) use virtualKey 0 + the string alone.
    ///
    /// The keycode matters for REMOTE DESKTOP clients (Chrome Remote Desktop, etc.): they
    /// forward the physical key, not the Unicode string, so a bare virtualKey 0 turns every
    /// character into keycode 0 = "A". Native apps / Citrix read the Unicode string, so the
    /// extra real keycode is harmless there. (Chars with no US key deliberately keep vk 0
    /// instead of a made-up fallback key, which could compete with the string and render a
    /// wrong glyph.)
    var forceUnicodeOnly = true
    /// Recheck before each key press; releases remain allowed to avoid stuck keys.
    var canPostPress: () -> Bool = { true }

    /// Modifier flags currently "held" (driven by shiftDown/shiftUp from the planner).
    /// Every posted event reflects these, exactly like real hardware while Shift is held.
    private var heldFlags: CGEventFlags = []

    init() {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.localEventsSuppressionInterval = 0
        self.source = s
    }

    // MARK: Text characters

    func charDown(_ ch: Character) { postChar(ch, down: true) }
    func charUp(_ ch: Character) { postChar(ch, down: false) }

    // MARK: Special keys (backspace, arrows, return, tab)

    func keyDown(_ code: CGKeyCode) { postCode(code, down: true) }
    func keyUp(_ code: CGKeyCode) { postCode(code, down: false) }

    // MARK: Modifier (left Shift) — real key events around shifted-char runs

    // Modifiers mirror ONLY what the OS actually saw: the flag is set after a successful
    // post (down) and always cleared on release. A dropped CGEvent can therefore never
    // leave a modifier "stuck" in our mirror and silently shift every following character.
    //
    // Real keyboards report modifiers as `flagsChanged` events (carrying the new flag state
    // + the left/right device bit), NOT as keyDown/keyUp. A plain keyDown for keycode 56 is
    // ignored by Chrome and by remote-desktop clients that track modifier state themselves,
    // so e.g. "?" arrived as "/" in Chrome Remote Desktop. Post the genuine event type.
    func shiftDown()  { if postModifier(KeyMap.shift,  flag: .maskShift,     device: 0x02, down: true)  { heldFlags.insert(.maskShift) } }
    func shiftUp()    { heldFlags.remove(.maskShift);     _ = postModifier(KeyMap.shift,  flag: .maskShift,     device: 0x02, down: false) }
    func optionDown() { if postModifier(KeyMap.option, flag: .maskAlternate, device: 0x20, down: true)  { heldFlags.insert(.maskAlternate) } }
    func optionUp()   { heldFlags.remove(.maskAlternate); _ = postModifier(KeyMap.option, flag: .maskAlternate, device: 0x20, down: false) }

    /// Idempotent safety reset — release any modifier we might be holding and clear the
    /// mirror. Posting an already-up modifier is a no-op for the OS, so calling this on
    /// abort/finish guarantees a run can never leave Shift/Option stuck for the user's own
    /// subsequent typing. (Releasing an already-up key never produces a character.)
    func resetModifiers() {
        if heldFlags.contains(.maskShift) {
            heldFlags.remove(.maskShift)
            _ = postModifier(KeyMap.shift, flag: .maskShift, device: 0x02, down: false)
        }
        if heldFlags.contains(.maskAlternate) {
            heldFlags.remove(.maskAlternate)
            _ = postModifier(KeyMap.option, flag: .maskAlternate, device: 0x20, down: false)
        }
        heldFlags = []
    }

    // MARK: Posting (text characters, special keys, and the ⌘V paste shortcut)

    /// Synthesize a single ⌘V: Command down, V down (⌘ held), V up, Command up. Used by the
    /// paste-delivery path. Posts at the HID tap like every other event, so the target sees a
    /// genuine paste. One atomic insert — nothing for a fragile editor to drop/merge/duplicate.
    func pasteShortcut() {
        let cmd: CGKeyCode = 0x37   // kVK_Command (left ⌘)
        let v: CGKeyCode = 0x09     // kVK_ANSI_V
        post(cmd, down: true,  flags: .maskCommand)
        post(v,   down: true,  flags: .maskCommand)
        post(v,   down: false, flags: .maskCommand)
        post(cmd, down: false, flags: [])
    }

    /// Low-level single keycode post with explicit flags (used by `pasteShortcut`).
    private func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard !down || canPostPress() else { return }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        e.timestamp = mach_absolute_time()
        e.post(tap: .cghidEventTap)
    }

    @discardableResult
    private func postChar(_ ch: Character, down: Bool) -> Bool {
        guard !down || canPostPress() else { return false }
        // Real US keycode whenever the char has one (so keycode-forwarding remote desktops
        // see the right key); otherwise vk 0 (forceUnicodeOnly) or a plausible fallback key.
        let stroke = KeyMap.stroke(for: ch)
        let vk = stroke?.code ?? (forceUnicodeOnly ? 0 : KeyMap.fallbackCode(for: ch))
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return false }
        if down {
            let u = Array(String(ch).utf16)
            u.withUnsafeBufferPointer { buf in
                e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
        }
        finalize(e, flags: heldFlags)
        e.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    private func postCode(_ code: CGKeyCode, down: Bool) -> Bool {
        guard !down || canPostPress() else { return false }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return false }
        finalize(e, flags: heldFlags)
        e.post(tap: .cghidEventTap)
        return true
    }

    /// A modifier press/release as a real `flagsChanged` event: `flag` (+ the device-dependent
    /// left-key bit) is added on press, removed on release, on top of the other held modifiers.
    @discardableResult
    private func postModifier(_ code: CGKeyCode, flag: CGEventFlags, device: UInt64, down: Bool) -> Bool {
        guard !down || canPostPress() else { return false }
        guard let e = CGEvent(source: source) else { return false }
        e.type = .flagsChanged
        e.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
        var flags = heldFlags
        flags.remove(flag)
        if down { flags.insert(flag); flags.insert(CGEventFlags(rawValue: device)) }
        e.flags = flags
        e.timestamp = mach_absolute_time()
        e.post(tap: .cghidEventTap)
        return true
    }

    private func finalize(_ e: CGEvent, flags: CGEventFlags) {
        e.flags = flags
        e.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        // Match what real hardware events actually carry: the kernel stamps CGEvents with
        // mach_absolute_time() (the monotonic TICK counter). On Intel the timebase is 1:1
        // so ticks ≈ ns (matching the stale "nanoseconds" header comment); on Apple Silicon
        // one tick = 41.67 ns, so the field is ticks, NOT ns. Using true ns (clock_gettime)
        // would read ~42x out of band to a tap on M-series — the opposite of the goal.
        e.timestamp = mach_absolute_time()
    }
}

/// Holds an IOPMAssertion so the display won't sleep mid-run. (Reused from Cursor+.)
final class PowerAssertion {

    private var id: IOPMAssertionID = 0
    private var active = false

    func begin() {
        guard !active else { return }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Typer+ typing" as CFString,
            &newID)
        if result == kIOReturnSuccess { id = newID; active = true }
    }

    func end() {
        guard active else { return }
        IOPMAssertionRelease(id)
        active = false
        id = 0
    }

    deinit { end() }   // never leak the display-sleep assertion
}
