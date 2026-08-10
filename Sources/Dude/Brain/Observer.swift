import SwiftUI

/// Watches the screen in the background on a timer. Records what you're doing
/// into local memory, and — when it looks like you could use a hand — has Dude
/// start a conversation on his own.
///
/// Cost-conscious: each tick captures locally and compares a fingerprint; only
/// a *changed* screen spends an API call. Static/idle screens are free.
@MainActor
final class Observer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastSummary = ""
    @Published private(set) var lastObservedAt: Date?

    private let memory: MemoryStore
    private let brain: Brain
    private let client = GeminiClient()
    private var task: Task<Void, Never>?
    private var lastSignature: [UInt8]?
    private var lastProactiveAt: Date?

    private let changeThreshold: Double = 5.0
    /// Don't nag: at most one unprompted offer of help per this many seconds.
    private let proactiveCooldown: TimeInterval = 300

    private static let observeSystem = """
    You quietly watch the user's screen. Reply in exactly two lines, nothing else.
    Line 1: a short phrase (10 words or fewer) naming the app and what they're doing.
    Line 2: If they clearly look stuck or would obviously welcome help right now \
    (an error on screen, a confusing form, repeated failed attempts, a question \
    they're clearly stuck on), write "HELP:" then one short, natural offer of help \
    (20 words or fewer, like a friend glancing over). Otherwise write exactly \
    "HELP: none". Be conservative — only offer when it's genuinely useful, and keep \
    it low-key, not peppy.
    """
    private static let observeQuestion = "What's happening, and do they need help?"

    init(memory: MemoryStore, brain: Brain) {
        self.memory = memory
        self.brain = brain
    }

    func start() {
        guard !isRunning, Secrets.hasKey else { return }
        isRunning = true
        task = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled && isRunning {
            let seconds = Secrets.observeIntervalSeconds
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                break
            }
            guard !Task.isCancelled, isRunning else { break }
            await tick()
        }
    }

    private func tick() async {
        guard Secrets.hasKey else { return }
        guard let shot = try? await ScreenCapture.captureMainDisplay() else { return }

        // Skip the API call if the screen looks the same as last time.
        if let last = lastSignature,
           ScreenCapture.meanAbsDifference(shot.signature, last) < changeThreshold {
            lastSignature = shot.signature
            return
        }
        lastSignature = shot.signature

        // Show the "at a laptop" emote while checking (only if he's idle).
        let showedWorking = brain.mood == .idle && !brain.isBusy
        if showedWorking { brain.setWorking() }
        defer { if showedWorking, brain.mood == .working { brain.settle() } }

        guard let reply = try? await client.ask(
            system: Self.observeSystem,
            question: Self.observeQuestion,
            imageBase64: shot.jpegBase64
        ) else { return }

        let (summary, help) = parse(reply)
        if !summary.isEmpty {
            memory.record(summary)
            lastSummary = summary
            lastObservedAt = Date()
        }

        if let help, shouldOfferHelp() {
            lastProactiveAt = Date()
            brain.proactivelySay(help)
        }
    }

    // MARK: - Helpers

    private func shouldOfferHelp() -> Bool {
        guard let last = lastProactiveAt else { return true }
        return Date().timeIntervalSince(last) > proactiveCooldown
    }

    private func parse(_ text: String) -> (summary: String, help: String?) {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let summary = lines.first(where: { !$0.uppercased().hasPrefix("HELP:") }) ?? ""

        var help: String?
        if let helpLine = lines.first(where: { $0.uppercased().hasPrefix("HELP:") }) {
            let value = helpLine.dropFirst("HELP:".count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value.lowercased() != "none" { help = value }
        }
        return (summary, help)
    }
}
