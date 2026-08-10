import SwiftUI

/// The full desktop pet: an optional speech bubble, the mascot, and an ask field
/// that appears when you click him. Reports its measured size via `onResize` so
/// the hosting panel can size its window to fit.
struct PetRootView: View {
    @ObservedObject var brain: Brain
    var onResize: (CGSize) -> Void = { _ in }

    @State private var askOpen = false
    @State private var question = ""
    /// True when the ask field was opened by the ⌃⌥D hotkey, so it starts in
    /// voice mode. A click opens it in plain typing mode.
    @State private var startInVoice = false

    var body: some View {
        VStack(spacing: 4) {
            if let bubble = bubbleText {
                SpeechBubble(text: bubble)
                    .onTapGesture { dismissBubble() }
            }

            MascotView(brain: brain)
                .contentShape(Rectangle())
                .onTapGesture { toggleAsk() }

            if askOpen {
                AskField(brain: brain, text: $question, onSubmit: submit, autoStartVoice: startInVoice)
            }
        }
        .padding(8)
        // Hug the content so the measured size is the *ideal* size, then report
        // it up so the panel can resize its window to match.
        .fixedSize()
        .background(GeometryReader { geo in
            Color.clear.preference(key: ContentSizeKey.self, value: geo.size)
        })
        .onPreferenceChange(ContentSizeKey.self) { onResize($0) }
        .onReceive(NotificationCenter.default.publisher(for: .dudeOpenAsk)) { _ in
            startInVoice = true
            askOpen = true
        }
    }

    private var bubbleText: String? {
        if brain.mood == .dancing {
            return brain.latestReply.isEmpty ? "🕺" : brain.latestReply
        }
        // While he's walking over or crouched at the laptop, keep quiet — he's
        // busy, but he does his talking once he's back.
        if brain.mood == .walking || brain.mood == .atLaptop { return nil }
        // Show whatever he's currently saying; only fall back to the thinking
        // dots when he's busy and hasn't said anything yet.
        guard !brain.latestReply.isEmpty else {
            return brain.isBusy ? "…" : nil
        }
        if brain.awaitingConfirmation {
            return brain.latestReply + "\n\n(y = yes · n = no)"
        }
        return brain.latestReply
    }

    private func toggleAsk() {
        if !brain.latestReply.isEmpty {
            dismissBubble()
        }
        if !askOpen { startInVoice = false }  // a click opens in typing mode
        askOpen.toggle()
    }

    private func submit() {
        let q = question
        question = ""
        askOpen = false
        Task { await brain.ask(q) }
    }

    private func dismissBubble() {
        brain.clearMessages()
        brain.settle()
    }
}
