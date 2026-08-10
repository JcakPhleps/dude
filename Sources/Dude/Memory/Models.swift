import Foundation

/// What Dude knows about you from setup — the "info you give him."
struct DudeProfile: Codable, Equatable {
    var name: String = ""
    var about: String = ""
    /// e.g. ["x": "@handle", "github": "jackphelps"]
    var socialHandles: [String: String] = [:]

    var isEmpty: Bool {
        name.isEmpty && about.isEmpty && socialHandles.isEmpty
    }

    /// A compact system-prompt-friendly description of the user.
    var briefing: String {
        var parts: [String] = []
        if !name.isEmpty { parts.append("The user's name is \(name).") }
        if !about.isEmpty { parts.append("About them: \(about)") }
        if !socialHandles.isEmpty {
            let handles = socialHandles.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            parts.append("Social: \(handles)")
        }
        return parts.isEmpty ? "No setup info provided yet." : parts.joined(separator: " ")
    }
}

/// One thing Dude noticed on screen, kept locally.
struct Observation: Codable, Identifiable, Equatable {
    var id = UUID()
    var timestamp = Date()
    var summary: String
}
