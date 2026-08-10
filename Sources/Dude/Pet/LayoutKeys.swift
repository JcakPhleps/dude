import SwiftUI

/// Reports a subview's measured size up the tree (used to size the panel window
/// to its SwiftUI content).
struct ContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Reports a subview's measured height (used to grow the speech bubble up to a
/// cap before it starts scrolling).
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
