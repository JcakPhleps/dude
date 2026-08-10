import SwiftUI

/// Shared look-and-feel for Dude. Deliberately chunky and low-fi to match the
/// pixel-art mascot.
enum DudeTheme {
    /// Base size of a single "pixel" in the mascot sprite, in points.
    static let pixel: CGFloat = 6

    /// Sprites are authored on a 16-wide grid.
    static let spriteGrid = 16

    /// Ink used for the stick figure's outline.
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.14)

    /// Fill used for the figure's body highlights.
    static let body = Color(red: 0.98, green: 0.98, blue: 0.96)

    /// Speech-bubble background + border.
    static let bubbleFill = Color(red: 0.99, green: 0.99, blue: 0.97)
    static let bubbleBorder = ink
    static let bubbleText = ink

    /// A soft accent used sparingly (blinking cursor, highlights).
    static let accent = Color(red: 0.94, green: 0.42, blue: 0.28)

    /// Monospaced, slightly oversized — reads as retro terminal type.
    static func pixelFont(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}
