import SwiftUI

/// Orchestrates a single ask: capture the screen, pull in any relevant context
/// (memory, and Messages when asked), call Gemini, and drive the mascot's mood.
@MainActor
final class Brain: ObservableObject {
    enum Mood: Equatable {
        case idle
        case thinking
        case talking
        case stumped     // couldn't do it (no key / permission / error)
        case dancing     // showing off, no API call
        case working     // peering at your screen (background observer)
        case listening   // you're typing to him — leaning in
        case voice       // voice mode — holding the mic, hearing you out
        case walking     // strolling across the screen to an app's Dock icon
        case atLaptop    // crouched at the app with his laptop out, doing the thing
    }

    /// Set by the app so Dude can physically walk to a named app's Dock icon
    /// before acting on it. Returns true once he's arrived, false if we can't
    /// walk there (no Accessibility, or the app isn't in the Dock).
    var walkToApp: ((String) async -> Bool)?
    /// Walk him back to his usual corner.
    var walkHome: (() async -> Void)?

    @Published var mood: Mood = .idle
    @Published var latestReply: String = ""
    @Published var isBusy = false

    /// True while Dude has a staged action waiting on a yes/no. The UI watches
    /// this to show a "(y / n)" hint and to route bare y/n keypresses.
    @Published private(set) var awaitingConfirmation = false

    private let memory: MemoryStore
    private let client = GeminiClient()

    /// An outward action (text/email) Dude has proposed and is waiting on the
    /// user to confirm before it actually leaves the machine.
    private var pendingAction: ActionRunner.Pending? {
        didSet { awaitingConfirmation = pendingAction != nil }
    }

    /// Bubbles Dude still has to say, shown one after another. Lets him fire off
    /// a run of short messages back-to-back on his own, instead of one reply per
    /// user turn.
    private var messageQueue: [String] = []
    /// True while a `drainMessages` task is walking the queue, so we don't start
    /// a second one.
    private var speaking = false

    /// Cap on model↔tool round-trips per ask, so a confused loop can't spin.
    private let maxToolRounds = 5

    init(memory: MemoryStore) {
        self.memory = memory
    }

    /// Ask Dude a question. Handles dance requests and yes/no confirmations
    /// locally; everything else goes to the model with screen + context and Dude's
    /// action tools.
    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }

        if isDanceRequest(trimmed) {
            await performDance()
            return
        }

        // If Dude staged a send and is waiting on a yes/no, resolve that first.
        // Only a clear yes actually sends; a clear no cancels; anything else
        // keeps it staged and re-asks — we never fabricate or guess a send.
        if let pending = pendingAction {
            if isAffirmative(trimmed) { confirmPending(); return }
            if isNegative(trimmed) { cancelPending(); return }
            say("Just so I don't send the wrong thing — \(pending.confirmationPrompt)")
            return
        }

        clearMessages()
        isBusy = true
        mood = .thinking
        defer { isBusy = false }

        var notes: [String] = []

        // 1. See the screen.
        var shot: ScreenCapture.Shot?
        do {
            shot = try await ScreenCapture.captureMainDisplay()
        } catch ScreenCapture.CaptureError.permissionDenied {
            notes.append("I can't see your screen yet — grant Screen Recording in System Settings ▸ Privacy & Security.")
        } catch {
            notes.append("I had trouble grabbing the screen (\(error.localizedDescription)).")
        }

        // 2. Pull in personal-data sources — each only when the question is
        //    actually about it, and never in the background.
        var context: [String] = []

        if readMessagesEnabled, isMessageQuery(trimmed) {
            if !Permissions.hasFullDiskAccess {
                notes.append(fdaNote)
            } else if let msgs = try? MessagesSource.recentMessages(limit: 15) {
                context.append("The user's recent Messages (oldest → newest):\n" + formatMessages(msgs))
            } else {
                notes.append("I have disk access but couldn't read Messages — is iMessage/SMS set up on this Mac?")
            }
        }

        if isEmailQuery(trimmed) {
            if !Permissions.hasFullDiskAccess {
                notes.append(fdaNote)
            } else if let emails = try? MailSource.recentEmails(limit: 12) {
                context.append("Recent emails (newest first):\n" + formatEmails(emails))
            } else {
                notes.append("I have disk access, but I don't see an Apple Mail account on this Mac. If your email lives in another app (like Gmail in a browser), tell me and we can wire that up.")
            }
        }

        if isCalendarQuery(trimmed) {
            if let events = await EventKitSource.upcomingEvents() {
                context.append("Upcoming calendar events:\n" +
                    (events.isEmpty ? "(nothing in the next week)" : events.joined(separator: "\n")))
            } else {
                notes.append("I need Calendar access — approve the prompt, or enable Dude under Privacy & Security ▸ Calendars.")
            }
        }

        if isReminderQuery(trimmed) {
            if let reminders = await EventKitSource.openReminders() {
                context.append("Open reminders:\n" +
                    (reminders.isEmpty ? "(none)" : reminders.joined(separator: "\n")))
            } else {
                notes.append("I need Reminders access — approve the prompt, or enable Dude under Privacy & Security ▸ Reminders.")
            }
        }

        // 3. No key → stub mode so the app stays demoable.
        guard Secrets.hasKey else {
            show(stubReply(question: trimmed, shot: shot, notes: notes), mood: .stumped)
            memory.record("Asked: \(trimmed) (stub — no API key)")
            return
        }

        // 4. Real ask — a tool-calling loop so Dude can actually act, not just
        //    promise to. He keeps the thinking animation the whole time.
        await runToolLoop(question: trimmed, notes: notes, context: context, shot: shot)
    }

    /// Drives the model↔tool conversation: send the ask, run any tool calls the
    /// model makes, feed the results back, and repeat until it produces a reply.
    private func runToolLoop(question: String, notes: [String], context: [String], shot: ScreenCapture.Shot?) async {
        var userParts: [GeminiClient.Part] = []
        if let b64 = shot?.jpegBase64 { userParts.append(.image(base64: b64)) }
        userParts.append(.text(notes.isEmpty ? question : "\(question)\n\n(Note: \(notes.joined(separator: " ")))"))

        var history: [GeminiClient.Turn] = [.init(role: "user", parts: userParts)]
        let system = systemPrompt(context: context)

        for _ in 0..<maxToolRounds {
            let turn: GeminiClient.ModelTurn
            do {
                turn = try await client.generate(system: system, history: history, useTools: true)
            } catch {
                show("Hmm, I couldn't reach my brain: \(error.localizedDescription)", mood: .stumped)
                return
            }

            guard !turn.calls.isEmpty else {
                say(turn.text ?? "…")
                memory.record("Q: \(question) → A: \((turn.text ?? "").prefix(160))")
                return
            }

            // If he said something *alongside* calling a tool ("sure, sending
            // that now") let that land as its own bubble before he acts — so he
            // can talk and do in one turn, back-to-back, without a nudge.
            if let intro = turn.text, !intro.isEmpty { say(intro) }

            // Echo the model's tool calls back verbatim — id + thoughtSignature
            // included, or Gemini 3.x rejects the follow-up — then run them and
            // reply with each result so the model can compose a final message.
            history.append(.init(role: "model", parts: turn.calls.map {
                .functionCall(name: $0.name, argsJSON: $0.argsJSON,
                              id: $0.id, thoughtSignature: $0.thoughtSignature)
            }))

            var responses: [GeminiClient.Part] = []
            for call in turn.calls {
                let outcome = await ActionRunner.handle(name: call.name, args: call.args)
                let result: String
                switch outcome {
                case .done(let r):
                    memory.record("Did: \(r)")
                    result = r
                case .failed(let why):
                    result = "FAILED: \(why)"
                case .staged(let pending, let note):
                    pendingAction = pending
                    result = note
                }
                responses.append(.functionResponse(name: call.name, id: call.id, result: result))
            }
            history.append(.init(role: "user", parts: responses))
        }

        // Ran out of rounds without a plain-text reply.
        say(pendingAction?.confirmationPrompt ?? "Okay, handled what I could.")
    }

    // MARK: - Confirming a staged action

    /// The user said yes (typed, or the `y` key) to a staged send/command.
    func confirmPending() {
        guard let pending = pendingAction, !isBusy else { return }
        pendingAction = nil
        Task { await commit(pending) }
    }

    /// The user said no (typed, or the `n` key). Drop the staged action.
    func cancelPending() {
        guard pendingAction != nil else { return }
        pendingAction = nil
        say("Cool, left it alone.")
    }

    /// Run a previously-staged outward action after the user confirmed. If it's
    /// tied to an app, Dude walks over to its Dock icon, does it at his laptop,
    /// and strolls back before reporting.
    private func commit(_ pending: ActionRunner.Pending) async {
        clearMessages()   // drop the confirm bubble; he's on it now
        isBusy = true
        mood = .thinking
        defer { isBusy = false }

        let arrived = await walkOver(toApp: pending.targetApp)
        let outcome = await ActionRunner.commit(pending)
        if arrived { await walkHome?() }

        switch outcome {
        case .done(let result):
            say(result)
            memory.record("Did: \(result)")
        case .failed(let why):
            show(why, mood: .stumped)
        case .staged:
            show("…", mood: .idle)
        }
    }

    /// Try to stroll over to `app`'s Dock icon and crouch down with the laptop.
    /// Returns true if he actually walked (so the caller knows to send him home
    /// afterward); false means he's working in place.
    private func walkOver(toApp app: String?) async -> Bool {
        guard let app, let walk = walkToApp else { mood = .thinking; return false }
        mood = .walking
        if await walk(app) {
            mood = .atLaptop
            return true
        }
        mood = .thinking
        return false
    }

    // MARK: - Talking (a queue of bubbles)

    /// Have Dude say something. A reply with blank-line breaks lands as several
    /// bubbles in a row, each held for a beat before the next — so he can talk
    /// in a natural run of short messages instead of one wall of text, and keep
    /// going on his own without the user prompting between each.
    func say(_ message: String) {
        enqueue(splitIntoMessages(message))
    }

    /// A single terminal message with an explicit mood (errors, stub replies).
    /// Clears anything queued so it doesn't get talked over.
    private func show(_ text: String, mood m: Mood) {
        messageQueue.removeAll()
        latestReply = text
        mood = m
    }

    /// Wipe anything queued or on screen (the user dismissed the bubble).
    func clearMessages() {
        messageQueue.removeAll()
        latestReply = ""
    }

    private func enqueue(_ messages: [String]) {
        guard !messages.isEmpty else { return }
        messageQueue.append(contentsOf: messages)
        guard !speaking else { return }
        speaking = true
        Task { await drainMessages() }
    }

    private func drainMessages() async {
        defer { speaking = false }
        while !messageQueue.isEmpty {
            let next = messageQueue.removeFirst()
            latestReply = next
            if mood != .dancing { mood = .talking }
            // Hold on the final line; between lines, pause long enough to read.
            if !messageQueue.isEmpty {
                try? await Task.sleep(nanoseconds: dwell(for: next))
            }
        }
    }

    /// Split a reply on blank lines into separate bubbles, trimmed and non-empty.
    private func splitIntoMessages(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Roughly reading time for a bubble before the next one: a base beat plus a
    /// little per word, capped so a long one doesn't stall the whole run.
    private func dwell(for message: String) -> UInt64 {
        let words = message.split { $0 == " " || $0 == "\n" }.count
        let seconds = min(6.0, 1.8 + Double(words) * 0.28)
        return UInt64(seconds * 1_000_000_000)
    }

    /// Called by the UI when the speech bubble is dismissed.
    func settle() {
        if mood != .dancing { mood = .idle }
    }

    /// The observer flips Dude into the "peering at your screen" emote while it
    /// checks the screen — but only if he's otherwise idle, so it never
    /// interrupts a chat.
    func setWorking() {
        if mood == .idle, !isBusy { mood = .working }
    }

    /// The ask field flips him into a leaning-in "listening" pose while you type,
    /// as long as he's not mid-thought or already replying.
    func beginListening() {
        if mood == .idle || mood == .working { mood = .listening }
    }

    /// Leave the listening pose when the ask field closes (unless he's moved on
    /// to thinking/talking/voice in the meantime).
    func endListening() {
        if mood == .listening { mood = .idle }
    }

    /// Voice mode: he holds the mic and hears you out. Overrides listening.
    func enterVoice() {
        if !isBusy, mood != .thinking, mood != .talking { mood = .voice }
    }

    func exitVoice() {
        if mood == .voice { mood = .idle }
    }

    /// The observer calls this to have Dude start a conversation on his own when
    /// the screen suggests the user could use a hand. Won't stomp an existing
    /// bubble or interrupt an in-progress ask.
    func proactivelySay(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy, latestReply.isEmpty, messageQueue.isEmpty, mood != .dancing else { return }
        say(text)
        memory.record("Offered: \(text.prefix(120))")
    }

    // MARK: - Dance

    private func isDanceRequest(_ q: String) -> Bool {
        let l = q.lowercased()
        return l.contains("dance") || l.contains("boogie") || l.contains("bust a move")
    }

    private func performDance() async {
        isBusy = true
        mood = .dancing
        latestReply = ["🕺 watch this!", "💃 you asked for it!", "🎵 boogie time!", "✨ hit it!"]
            .randomElement() ?? "🕺 watch this!"
        try? await Task.sleep(nanoseconds: 4_200_000_000)
        latestReply = ""
        mood = .idle
        isBusy = false
        memory.record("Busted a move on request")
    }

    // MARK: - Messages

    private var readMessagesEnabled: Bool {
        UserDefaults.standard.object(forKey: "dude.readMessages") as? Bool ?? true
    }

    private let fdaNote = "I can't read that yet. Turn on Full Disk Access for Dude in System Settings ▸ Privacy & Security ▸ Full Disk Access, then FULLY QUIT and reopen me — the grant only kicks in on a fresh launch."

    private func isMessageQuery(_ q: String) -> Bool {
        let l = q.lowercased()
        return ["message", "text", "imessage", "dm", "hear from", "who wrote", "any word"].contains { l.contains($0) }
    }

    private func isEmailQuery(_ q: String) -> Bool {
        let l = q.lowercased()
        return ["email", "e-mail", "inbox", "mailbox", "gmail"].contains { l.contains($0) } || l.contains("mail")
    }

    private func isCalendarQuery(_ q: String) -> Bool {
        let l = q.lowercased()
        return ["calendar", "schedule", "agenda", "event", "meeting", "appointment", "what's on", "whats on", "free today", "busy"].contains { l.contains($0) }
    }

    private func isReminderQuery(_ q: String) -> Bool {
        let l = q.lowercased()
        return ["reminder", "to-do", "todo", "to do", "task"].contains { l.contains($0) }
    }

    // MARK: - Confirmation

    private func isAffirmative(_ q: String) -> Bool {
        let l = normalizeConfirm(q)
        let words = ["yes", "yep", "yeah", "yea", "ya", "yah", "yuh", "yup", "yis",
                     "sure", "ok", "okay", "k", "kk", "do it", "doit", "send it",
                     "sendit", "send", "send that", "go", "go ahead", "go for it",
                     "please", "confirm", "confirmed", "y", "yes please", "mhm",
                     "mmhm", "absolutely", "definitely", "yessir", "sounds good",
                     "sgtm", "👍", "✅", "🆗"]
        return words.contains { l == $0 || l.hasPrefix($0 + " ") }
    }

    private func isNegative(_ q: String) -> Bool {
        let l = normalizeConfirm(q)
        let words = ["no", "nope", "nah", "naw", "don't", "dont", "do not",
                     "cancel", "stop", "nevermind", "never mind", "wait", "hold on",
                     "n", "no thanks", "negative", "abort", "❌", "👎"]
        return words.contains { l == $0 || l.hasPrefix($0 + " ") }
    }

    /// Lowercase and strip surrounding punctuation/whitespace so "Yes!", " ya. ",
    /// etc. still read as a plain confirmation.
    private func normalizeConfirm(_ q: String) -> String {
        q.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.union(.symbols).inverted)
    }

    private func formatMessages(_ msgs: [MessageItem]) -> String {
        guard !msgs.isEmpty else { return "(no recent messages found)" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, HH:mm"
        return msgs
            .map { "[\(fmt.string(from: $0.date))] \($0.sender): \($0.body)" }
            .joined(separator: "\n")
    }

    private func formatEmails(_ emails: [EmailItem]) -> String {
        guard !emails.isEmpty else { return "(no recent emails found)" }
        return emails
            .map { e in
                let tail = e.snippet.isEmpty ? "" : " — \(e.snippet)"
                return "• from \(e.from): \(e.subject)\(tail)"
            }
            .joined(separator: "\n")
    }

    // MARK: - Prompt assembly

    private func systemPrompt(context: [String]) -> String {
        let now = DateFormatter()
        now.dateFormat = "EEEE, MMMM d, yyyy 'at' HH:mm"
        var prompt = """
        You are "dude", the user's desktop buddy. You can see their screen and \
        their personal stuff (messages, email, calendar, reminders) and help with \
        what they're doing.

        Right now it is \(now.string(from: Date())) (the user's local time). Use \
        this to resolve "today", "tomorrow", "in an hour", etc. into concrete \
        times.

        Talk like a real person, not a mascot performing casualness. Be easygoing \
        and genuine — don't force slang, hype, exclamation points, or "chill" \
        energy. Relaxed is a default, not a bit. Keep it short: usually a sentence \
        or two, sometimes just a few words. Say the useful thing and stop; skip \
        filler and pep. Never mention being an AI or a model.

        You can actually DO things through your tools: send a text (send_message), \
        send an email (send_email), add a calendar event (create_calendar_event), \
        set a reminder (create_reminder), and control Spotify (control_spotify). \
        And for anything else on the Mac that those don't cover — organizing files, \
        opening or quitting apps, changing a setting, automating an app, cleaning \
        up the desktop, whatever — use run_command: give a short plain-English \
        summary plus the exact shell (zsh) or AppleScript to run, and set `app` to \
        the app it acts on when it's about one specific app. You can see the screen, \
        so read what's actually there (desktop files, the open app) and target the \
        command precisely. Favor reversible, least-destructive commands: move junk \
        to the Trash (~/.Trash) instead of deleting it, never use sudo, and keep the \
        script scoped to exactly what was asked. When the user asks you to do \
        something, CALL THE TOOL — do it now in this same turn. Never reply with \
        "on it", "finding it", "let me look", "one sec", or any promise to follow up \
        later: you get exactly one turn, so either do the thing and report the \
        result, or ask a needed clarifying question. Nothing in between. If a request \
        needs info you don't have (like a phone number or address), just ask for it \
        plainly.

        Sending a text or email, and running a command, are staged for a quick \
        confirmation — after you call send_message/send_email/run_command, briefly \
        tell the user what you're about to do and let them okay it. Other actions \
        run immediately, so just confirm they're done. NEVER claim you sent a \
        message, sent an email, ran a command, or did anything unless you actually \
        called the tool for it in this conversation and it reported success — if you \
        haven't, don't say you did.

        What you know about the user:
        \(memory.profile.briefing)

        Recent things you've noticed (most recent last):
        \(recentContext())
        """
        for block in context {
            prompt += "\n\n\(block)"
        }
        return prompt
    }

    private func recentContext() -> String {
        let recent = memory.recentObservations()
        guard !recent.isEmpty else { return "(nothing yet)" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return recent
            .map { "- [\(fmt.string(from: $0.timestamp))] \($0.summary)" }
            .joined(separator: "\n")
    }

    // MARK: - Stub mode

    private func stubReply(question: String, shot: ScreenCapture.Shot?, notes: [String]) -> String {
        var lines = ["Hey! I heard: “\(question)”."]
        if let shot {
            lines.append("I can see your screen (\(shot.pixelWidth)×\(shot.pixelHeight)) — but I need a brain to actually read it.")
        }
        lines.append(contentsOf: notes)
        lines.append("Grab a free Google key at aistudio.google.com/apikey, drop it at \(Secrets.configPath) (or set GOOGLE_API_KEY), and I'll really answer.")
        return lines.joined(separator: " ")
    }
}
