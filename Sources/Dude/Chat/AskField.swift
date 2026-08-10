import SwiftUI

/// The little pixel input where you type — or talk — to Dude. While it's open he
/// leans in (listening); tap the mic (or open with ⌃⌥D) and he holds one up while
/// you speak. Start typing at any point and it drops back to a normal text box.
struct AskField: View {
    @ObservedObject var brain: Brain
    @Binding var text: String
    var onSubmit: () -> Void
    /// When opened via the ⌃⌥D hotkey, start listening right away.
    var autoStartVoice: Bool = false

    @FocusState private var focused: Bool
    @StateObject private var voice = VoiceInput()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(">")
                    .font(DudeTheme.pixelFont(12))
                    .foregroundStyle(DudeTheme.accent)

                TextField(voice.isRecording ? "listening… (or just type)" : "ask dude…", text: $text)
                    .textFieldStyle(.plain)
                    .font(DudeTheme.pixelFont(12))
                    .foregroundStyle(DudeTheme.ink)
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .disabled(brain.isBusy)

                Button(action: voice.toggle) {
                    Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(voice.isRecording ? DudeTheme.accent : DudeTheme.ink)
                }
                .buttonStyle(.plain)
                .help(voice.isRecording ? "Stop listening" : "Talk to Dude")
                .disabled(brain.isBusy)
            }

            // Live transcript sits in its own line (not the text field) so the
            // field staying empty is a reliable "user hasn't typed" signal.
            if voice.isRecording {
                Text(voice.transcript.isEmpty ? "…" : voice.transcript)
                    .font(DudeTheme.pixelFont(10))
                    .foregroundStyle(DudeTheme.ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 208, alignment: .leading)
            }

            if let status = voice.status {
                Text(status)
                    .font(DudeTheme.pixelFont(9))
                    .foregroundStyle(DudeTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 208, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(DudeTheme.bubbleFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(DudeTheme.bubbleBorder, lineWidth: 2)
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .onAppear {
            focused = true
            brain.beginListening()
            // A finished voice transcript (mic tap or 4s of silence) fills the
            // field and sends it.
            voice.onFinal = { spoken in
                text = spoken
                onSubmit()
            }
            if autoStartVoice { Task { await voice.start() } }
        }
        .onDisappear {
            voice.stop(final: false)
            brain.endListening()
        }
        // The moment you type anything, bail out of voice into typing mode.
        .onChange(of: text) { _, typed in
            if voice.isRecording, !typed.isEmpty { voice.stop(final: false) }
        }
        // Mic on → he holds the mic; mic off → back to leaning-in listening.
        .onChange(of: voice.isRecording) { _, recording in
            if recording { brain.enterVoice() } else { brain.beginListening() }
        }
    }
}
