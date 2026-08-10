import SwiftUI

/// First-run / anytime setup: the info you give Dude about yourself. Feeds the
/// system prompt so his answers are grounded in who you are.
struct SetupView: View {
    @ObservedObject var memory: MemoryStore
    var onDone: () -> Void

    // Common handles surfaced as explicit fields; stored in profile.socialHandles.
    private let handleKeys = ["x", "instagram", "github", "linkedin"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up dude")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("What should I call you?").font(.headline)
                TextField("your name", text: $memory.profile.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Tell me about yourself").font(.headline)
                TextEditor(text: $memory.profile.about)
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Socials (optional)").font(.headline)
                ForEach(handleKeys, id: \.self) { key in
                    HStack {
                        Text(key).frame(width: 80, alignment: .leading)
                            .foregroundStyle(.secondary)
                        TextField("@handle", text: binding(for: key))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            if !Secrets.hasKey {
                Text("Tip: grab a free Google (Gemini) key at aistudio.google.com/apikey, then drop it at \(Secrets.configPath) (or set GOOGLE_API_KEY) so I can actually read your screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") {
                    memory.saveProfile()
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { memory.profile.socialHandles[key] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    memory.profile.socialHandles.removeValue(forKey: key)
                } else {
                    memory.profile.socialHandles[key] = trimmed
                }
            }
        )
    }
}
