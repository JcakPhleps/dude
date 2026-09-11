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
    /// speaks. Returns false if Accessibility isn't granted.
    ///
    /// The pointer doesn't teleport: it *glides* over along a curved, eased,
    /// slightly jittery path, then settles a beat before pressing. A reCAPTCHA
    /// "I'm not a robot" checkbox scores how the cursor arrives, so an organic
    /// approach clears it far more often than a straight-line snap — and it
    /// looks like a real hand on camera.
    @discardableResult
    static func click(at point: CGPoint) async -> Bool {
        guard isTrusted else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)

        await humanGlide(to: point, source: source)
        // Settle like a person lining up the click, then a human-length press.
        try? await Task.sleep(nanoseconds: UInt64.random(in: 90_000_000...200_000_000))
        post(.leftMouseDown, at: point, source: source)
        try? await Task.sleep(nanoseconds: UInt64.random(in: 60_000_000...120_000_000))
        post(.leftMouseUp, at: point, source: source)
        return true
    }

    /// Slide the cursor from wherever it is now to `target` with an eased speed
    /// curve, a gentle sideways bow (like a wrist arc), and a little per-step
    /// jitter — the movement signature reCAPTCHA reads as human.
    private static func humanGlide(to target: CGPoint, source: CGEventSource?) async {
        let start = CGEvent(source: nil)?.location ?? target
        let dx = target.x - start.x, dy = target.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 2 else { post(.mouseMoved, at: target, source: source); return }

        // More steps for longer travel, but keep it snappy overall (~0.2–0.6s).
        let steps = max(12, min(48, Int(distance / 12)))
        // Unit normal to the travel direction, scaled into a shallow bow whose
        // side and depth vary run to run so it never traces the same arc twice.
        let normalX = -dy / distance, normalY = dx / distance
        let bow = Double.random(in: -0.18...0.18) * distance

        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2   // easeInOut
            let curve = sin(eased * .pi) * bow                            // peaks mid-travel
            let x = start.x + dx * eased + normalX * curve + Double.random(in: -0.6...0.6)
            let y = start.y + dy * eased + normalY * curve + Double.random(in: -0.6...0.6)
            post(.mouseMoved, at: CGPoint(x: x, y: y), source: source)
            try? await Task.sleep(nanoseconds: UInt64.random(in: 6_000_000...16_000_000))
        }
        post(.mouseMoved, at: target, source: source)   // land dead-on
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

    // MARK: - Scrolling

    /// Scroll wherever the pointer currently sits. `vertical` > 0 scrolls up,
    /// `horizontal` > 0 scrolls left; magnitudes are line counts. Delivered in a
    /// few small steps so it glides rather than jumping. Needs Accessibility.
    @discardableResult
    static func scroll(vertical: Int, horizontal: Int) async -> Bool {
        guard isTrusted else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let steps = 6
        let stepV = Int32(vertical / steps), stepH = Int32(horizontal / steps)
        guard stepV != 0 || stepH != 0 else { return true }
        for _ in 0..<steps {
            if let event = CGEvent(scrollWheelEvent2Source: source, units: .line,
                                   wheelCount: 2, wheel1: stepV, wheel2: stepH, wheel3: 0) {
                event.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 22_000_000)
        }
        return true
    }

    // MARK: - Keyboard shortcuts

    /// Press a single key or a modifier chord like `cmd+l`, `cmd+shift+t`,
    /// `escape`, `tab`, `down`, `pageup`. Combine modifiers with `+`; the final
    /// token is the key. Returns false if Accessibility is off or the key name
    /// isn't recognized.
    @discardableResult
    static func pressKeys(_ combo: String) async -> Bool {
        guard isTrusted else { return false }
        let tokens = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = tokens.last, let code = keyCode(for: keyName) else { return false }

        var flags: CGEventFlags = []
        for modifier in tokens.dropLast() {
            switch modifier {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧":          flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            default: break
            }
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 45_000_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Map a key name to its US-ANSI virtual keycode. Covers letters, digits,
    /// and the navigation/editing keys an agent actually reaches for.
    private static func keyCode(for name: String) -> CGKeyCode? {
        let named: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "spacebar": 49,
            "delete": 51, "backspace": 51, "forwarddelete": 117,
            "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "comma": 43, "period": 47, "slash": 44, "minus": 27, "equal": 24,
            "semicolon": 41, "quote": 39, "leftbracket": 33, "rightbracket": 30,
            "backslash": 42, "grave": 50, "backtick": 50,
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
            "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
            "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
            "y": 16, "z": 6,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
            "7": 26, "8": 28, "9": 25,
        ]
        return named[name]
    }
}
