import Foundation

/// Local, on-disk memory for Dude. Everything stays under
/// ~/Library/Application Support/Dude — nothing leaves the machine except
/// what's sent to the Claude API when you ask a question.
@MainActor
final class MemoryStore: ObservableObject {
    @Published var profile = DudeProfile()
    @Published private(set) var observations: [Observation] = []

    private let dir: URL
    private let profileURL: URL
    private let observationsURL: URL

    /// Cap on how many recent observations we keep in the working set.
    private let maxObservations = 200

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("Dude", isDirectory: true)
        profileURL = dir.appendingPathComponent("profile.json")
        observationsURL = dir.appendingPathComponent("observations.json")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Reads

    /// The most recent observations, newest last, for feeding into context.
    func recentObservations(limit: Int = 12) -> [Observation] {
        Array(observations.suffix(limit))
    }

    // MARK: - Writes

    func saveProfile() {
        write(profile, to: profileURL)
    }

    func record(_ summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        observations.append(Observation(summary: trimmed))
        if observations.count > maxObservations {
            observations.removeFirst(observations.count - maxObservations)
        }
        write(observations, to: observationsURL)
    }

    // MARK: - Persistence

    private func load() {
        if let p: DudeProfile = read(from: profileURL) { profile = p }
        if let o: [Observation] = read(from: observationsURL) { observations = o }
    }

    private func read<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
