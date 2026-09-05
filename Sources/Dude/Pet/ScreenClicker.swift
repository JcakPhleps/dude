import AppKit
import ApplicationServices
import CoreGraphics

/// Synthesizes a real mouse click at a point on screen, so Dude can actually
/// press things — check a box, tap a button, follow a link — not just talk
/// about them.
///
/// Posting synthetic input goes through CoreGraphics' HID event tap, which (like
/// reading the Dock's layout) needs Accessibility permission. Without it `click`
/// returns false and the caller reports that back to the user.
@MainActor
enum ScreenClicker {

    /// Whether we're allowed to post synthetic input yet. Same grant that lets
    /// Dude walk to Dock icons, so once one works they both do.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Move the pointer to `point` and left-click once. `point` is in global
    /// display coordinates — top-left origin, points — the space `CGEvent`
    /// speaks. A tiny pause between press and release keeps it looking like a
    /// real click rather than a zero-length blip. Returns false if Accessibility
    /// isn't granted.
    @discardableResult
    static func click(at point: CGPoint) async -> Bool {
        guard isTrusted else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)

        // Glide the cursor over so the target registers a hover first, settle a
        // beat, then press and release.
        post(.mouseMoved, at: point, source: source)
        try? await Task.sleep(nanoseconds: 120_000_000)
        post(.leftMouseDown, at: point, source: source)
        try? await Task.sleep(nanoseconds: 90_000_000)
        post(.leftMouseUp, at: point, source: source)
        return true
    }

    private static func post(_ type: CGEventType, at point: CGPoint, source: CGEventSource?) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Type `text` into whatever's currently focused, one character at a time
    /// with a light stagger so it reads like real typing. Characters go in as
    /// Unicode (layout-independent), and newlines press Return. Needs the same
    /// Accessibility grant as clicking; returns false without it.
    @discardableResult
    static func type(_ text: String) async -> Bool {
        guard isTrusted else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in text {
            if character == "\n" || character == "\r" {
                pressReturn(source: source)
            } else {
                typeCharacter(character, source: source)
            }
            try? await Task.sleep(nanoseconds: 45_000_000)
        }
        return true
    }

    /// Post a key-down/up pair carrying `character` as a Unicode payload, so it
    /// lands regardless of the keyboard layout and without a keycode table.
    private static func typeCharacter(_ character: Character, source: CGEventSource?) {
        var utf16 = Array(String(character).utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Press the Return key (virtual keycode 36) for newlines / submitting.
    private static func pressReturn(source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
