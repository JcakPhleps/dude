import SwiftUI

/// A pixel-styled speech bubble with a little tail pointing down at the mascot.
/// Grows to fit the reply up to `maxHeight`, then scrolls — so long answers are
/// fully readable without the window running off the screen.
struct SpeechBubble: View {
    let text: String

    private let contentWidth: CGFloat = 220
    private let maxHeight: CGFloat = 200
    @State private var textHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                Text(text)
                    .font(DudeTheme.pixelFont(12))
                    .foregroundStyle(DudeTheme.bubbleText)
                    .multilineTextAlignment(.leading)
                    .frame(width: contentWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: contentWidth + 20, height: max(1, min(textHeight, maxHeight)))
            .background(RoundedRectangle(cornerRadius: 4).fill(DudeTheme.bubbleFill))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(DudeTheme.bubbleBorder, lineWidth: 2))
            .onPreferenceChange(ContentHeightKey.self) { textHeight = $0 }

            // Downward tail.
            Tail()
                .fill(DudeTheme.bubbleFill)
                .overlay(Tail().stroke(DudeTheme.bubbleBorder, lineWidth: 2))
                .frame(width: 14, height: 8)
                .offset(y: -1)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    private struct Tail: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: 0))
            p.addLine(to: CGPoint(x: rect.width / 2, y: rect.height))
            p.closeSubpath()
            return p
        }
    }
}
