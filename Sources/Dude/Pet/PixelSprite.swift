import SwiftUI

/// Renders a string-grid sprite (see `Sprites`) as crisp pixel blocks.
struct PixelSprite: View {
    let frame: [String]
    var pixel: CGFloat = DudeTheme.pixel

    var body: some View {
        let grid = DudeTheme.spriteGrid
        Canvas { context, _ in
            for (row, line) in frame.enumerated() {
                let chars = Array(line)
                for col in 0..<min(grid, chars.count) {
                    guard let color = Self.color(for: chars[col]) else { continue }
                    let rect = CGRect(
                        x: CGFloat(col) * pixel,
                        y: CGFloat(row) * pixel,
                        width: pixel,
                        height: pixel
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(
            width: CGFloat(grid) * pixel,
            height: CGFloat(frame.count) * pixel
        )
        .onAppear {
            assert(
                frame.allSatisfy { $0.count == grid },
                "Sprite rows must be \(grid) chars wide"
            )
        }
    }

    private static func color(for char: Character) -> Color? {
        switch char {
        case "K", "E": return DudeTheme.ink
        case "W": return DudeTheme.body
        case "A": return DudeTheme.accent   // props (e.g. the microphone)
        default: return nil // "." and anything else = transparent
        }
    }
}
