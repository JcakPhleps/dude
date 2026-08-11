import SwiftUI

/// First-run / anytime setup: the info you give Dude about yourself. Feeds the
/// system prompt so his answers are grounded in who you are.
struct SetupView: View {
    @ObservedObject var memory: MemoryStore
    var onDone: () -> Void

    // Common handles surfaced as explicit fields; stored in profile.socialHandles.
    private let handleKeys = ["x", "instagram", "github", "linkedin"]

    /// The Gemini key, loaded from ~/.dude/config.json and saved back on Done.
    @State private var apiKey = ""

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

            VStack(alignment: .leading, spacing: 8) {
                Text("Gemini API key").font(.headline)
                Text("Lets me actually see your screen and answer. Free, with a no-cost tier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("AIza…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    Link("Get a free key ↗", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.caption)
                    if usingEnvKey {
                        Text("Using a key from your environment.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    Secrets.setGoogleAPIKey(apiKey)
                    memory.saveProfile()
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { apiKey = Secrets.storedAPIKey ?? "" }
    }

    /// True when a key is coming from an env var (not the file) — the field edits
    /// the file, so we flag that the environment would still take precedence.
    private var usingEnvKey: Bool {
        Secrets.storedAPIKey == nil && Secrets.hasKey
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
