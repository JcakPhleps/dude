import AppKit
import EventKit
import Foundation

/// Things Dude can *do* on the machine (not just answer): send an iMessage,
/// send mail, drop something on the calendar, set a reminder, or drive Spotify.
///
/// Everything here runs on the main actor — NSAppleScript and AppKit both want
/// it, and it keeps the model's tool calls serialized against the UI.
///
/// Outward, hard-to-undo actions (sending a message or an email) are *staged*
/// rather than fired immediately: the Brain shows the user what it's about to
/// send and only runs it once they say go. Low-risk actions (calendar, reminder,
/// Spotify) run straight away.
@MainActor
enum ActionRunner {

    /// Shown when a screen-control action needs the Accessibility grant.
    static let accessibilityHint = "I need Accessibility turned on for Dude in System Settings ▸ Privacy & Security ▸ Accessibility (the same one that lets me walk to apps)."

    // MARK: - Tool schema handed to Gemini

    /// Gemini `functionDeclarations`. Lives in the dependency-free `AgentSpec` so
    /// the exact schema is shared with the behavior tests. `nonisolated` so the
    /// (non-actor) GeminiClient can build the request without hopping actors.
    nonisolated static func functionDeclarations() -> [[String: Any]] {
        AgentSpec.functionDeclarations()
    }

    /// A staged outward action awaiting the user's yes/no. Sendable so it can
    /// live on the Brain across awaits.
    enum Pending: Sendable {
        case message(recipient: String, body: String)
        case email(to: String, subject: String, body: String)
        case command(summary: String, language: String, script: String, app: String?)

        /// How Dude describes what he's about to do, so the user can confirm.
        var confirmationPrompt: String {
            switch self {
            case .message(let r, let b):
                return "Text \(r): “\(b)” — want me to send it?"
            case .email(let to, let subject, let b):
                let preview = b.count > 140 ? String(b.prefix(140)) + "…" : b
                return "Email \(to) — “\(subject)”: \(preview)\n\nSend it?"
            case .command(let summary, _, let script, _):
                let preview = script.count > 220 ? String(script.prefix(220)) + "…" : script
                return "\(summary)\n\n`\(preview)`\n\nRun it?"
            }
        }

        /// The Mac app this action targets, if any — used to walk Dude over to
        /// its Dock icon before it runs.
        var targetApp: String? {
            switch self {
            case .message: return "Messages"
            case .email: return "Mail"
            case .command(_, _, _, let app): return app
            }
        }
    }

    // MARK: - Dispatch

    /// Outcome of handling one tool call. `.staged` means we need the user to
    /// confirm before anything leaves the machine.
    enum Outcome: Sendable {
        case done(String)           // executed; string is fed back to the model
        case staged(Pending, note: String)
        case failed(String)
        /// The model wants Dude to walk over and click a spot on screen. `nx`/`ny`
        /// are normalized 0…1 (left→right, top→bottom) on the captured display;
        /// the Brain turns that into a real click. `label` is what he's clicking.
        case click(nx: Double, ny: Double, label: String)
        /// The model wants Dude to type into the focused field. `submit` presses
        /// Return afterward.
        case type(text: String, submit: Bool)
    }

    /// Route a model tool call to the right handler.
    static func handle(name: String, args: [String: String]) async -> Outcome {
        switch name {
        case "send_message":
            guard let r = ActionParsing.nonEmpty(args["recipient"]), let b = ActionParsing.nonEmpty(args["body"]) else {
                return .failed("Missing recipient or body.")
            }
            return .staged(.message(recipient: r, body: b),
                           note: "Staged — waiting for the user to confirm before sending.")

        case "send_email":
            guard let to = ActionParsing.nonEmpty(args["to"]), let s = ActionParsing.nonEmpty(args["subject"]), let b = ActionParsing.nonEmpty(args["body"]) else {
                return .failed("Missing to, subject, or body.")
            }
            return .staged(.email(to: to, subject: s, body: b),
                           note: "Staged — waiting for the user to confirm before sending.")

        case "create_calendar_event":
            guard let title = ActionParsing.nonEmpty(args["title"]), let start = ActionParsing.nonEmpty(args["start"]) else {
                return .failed("Missing title or start.")
            }
            return await createEvent(title: title, start: start, end: args["end"], notes: args["notes"])

        case "create_reminder":
            guard let title = ActionParsing.nonEmpty(args["title"]) else { return .failed("Missing title.") }
            return await createReminder(title: title, due: args["due"])

        case "control_spotify":
            guard let command = ActionParsing.nonEmpty(args["command"]) else { return .failed("Missing command.") }
            return spotify(command: command, query: args["query"])

        case "run_command":
            guard let summary = ActionParsing.nonEmpty(args["summary"]), let script = ActionParsing.nonEmpty(args["script"]) else {
                return .failed("Missing summary or script.")
            }
            let language = (ActionParsing.nonEmpty(args["language"]) ?? "shell").lowercased()
            return .staged(.command(summary: summary, language: language,
                                    script: script, app: ActionParsing.nonEmpty(args["app"])),
                           note: "Staged — waiting for the user to confirm before running it.")

        case "click_screen":
            guard let label = ActionParsing.nonEmpty(args["label"]),
                  let xRaw = ActionParsing.nonEmpty(args["x"]).flatMap(Double.init),
                  let yRaw = ActionParsing.nonEmpty(args["y"]).flatMap(Double.init) else {
                return .failed("Missing label or coordinates.")
            }
            // Model gives 0–1000 per axis; normalize to 0…1 and clamp so a stray
            // out-of-range point can't send the click off-screen.
            let nx = min(max(xRaw / 1000.0, 0), 1)
            let ny = min(max(yRaw / 1000.0, 0), 1)
            return .click(nx: nx, ny: ny, label: label)

        case "type_text":
            guard let text = ActionParsing.nonEmpty(args["text"]) else { return .failed("Nothing to type.") }
            let submit = (args["submit"] ?? "").lowercased() == "true"
            return .type(text: text, submit: submit)

        case "scroll":
            guard let dir = ActionParsing.nonEmpty(args["direction"])?.lowercased() else {
                return .failed("Missing direction.")
            }
            let amount = (args["amount"] ?? "medium").lowercased()
            let lines = amount.contains("large") ? 24 : amount.contains("small") ? 4 : 12
            var vertical = 0, horizontal = 0
            switch dir {
            case "down":  vertical = -lines
            case "up":    vertical = lines
            case "left":  horizontal = lines
            case "right": horizontal = -lines
            default: return .failed("Unknown scroll direction “\(dir)”.")
            }
            guard await ScreenClicker.scroll(vertical: vertical, horizontal: horizontal) else {
                return .failed(accessibilityHint)
            }
            return .done("Scrolled \(dir).")

        case "press_keys":
            guard let keys = ActionParsing.nonEmpty(args["keys"]) else { return .failed("No keys given.") }
            guard await ScreenClicker.pressKeys(keys) else {
                return .failed("Couldn't press “\(keys)” — \(accessibilityHint)")
            }
            return .done("Pressed \(keys).")

        default:
            return .failed("Unknown action \(name).")
        }
    }

    /// Run a staged action for real, after the user said yes.
    static func commit(_ pending: Pending) async -> Outcome {
        switch pending {
        case .message(let r, let b):   return await sendMessage(to: r, body: b)
        case .email(let to, let s, let b): return sendEmail(to: to, subject: s, body: b)
        case .command(let summary, let language, let script, _):
            return await runCommand(summary: summary, language: language, script: script)
        }
    }

    // MARK: - iMessage / Mail (AppleScript)

    private static func sendMessage(to recipient: String, body: String) async -> Outcome {
        // The AppleScript can only address a concrete handle, so turn a name
        // like "Gavin" into a phone/email first.
        guard let handle = await ContactResolver.handle(for: recipient) else {
            return .failed("I couldn't find “\(recipient)” in your Contacts. Give me their number or email and I'll send it.")
        }
        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant "\(ActionParsing.esc(handle))" of targetService
            send "\(ActionParsing.esc(body))" to targetBuddy
        end tell
        """
        if let error = runAppleScript(script) {
            return .failed("Couldn't send the message to \(recipient): \(error)")
        }
        return .done("Sent “\(body)” to \(recipient).")
    }

    private static func sendEmail(to: String, subject: String, body: String) -> Outcome {
        let script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"\(ActionParsing.esc(subject))", content:"\(ActionParsing.esc(body))", visible:true}
            tell newMessage
                make new to recipient at end of to recipients with properties {address:"\(ActionParsing.esc(to))"}
            end tell
            send newMessage
        end tell
        """
        if let error = runAppleScript(script) {
            return .failed("Couldn't send the email: \(error)")
        }
        return .done("Sent the email to \(to).")
    }

    // MARK: - Spotify (AppleScript)

    private static func spotify(command: String, query: String?) -> Outcome {
        let cmd = command.lowercased()
        let action: String
        switch cmd {
        case "play", "resume":       action = "play"
        case "pause", "stop":        action = "pause"
        case "next", "skip":         action = "next track"
        case "previous", "prev", "back": action = "previous track"
        case "play_track", "play_song", "search":
            guard let q = ActionParsing.nonEmpty(query) else { return .failed("Nothing to play — no query given.") }
            // Open a Spotify search then start playback. (The AppleScript API
            // can only play an exact URI, so we search via the app's URL scheme.)
            if let url = URL(string: "spotify:search:\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)") {
                NSWorkspace.shared.open(url)
            }
            runAppleScript("delay 1\ntell application \"Spotify\" to play")
            return .done("Searching Spotify for “\(q)” and starting it up.")
        default:
            return .failed("Don't know the Spotify command “\(command)”.")
        }
        if let error = runAppleScript("tell application \"Spotify\" to \(action)") {
            return .failed("Spotify didn't cooperate: \(error)")
        }
        return .done("Spotify: \(cmd).")
    }

    // MARK: - General "do anything" command

    /// Run an approved free-form command — a zsh script or an AppleScript. The
    /// result string (trimmed, capped) is what Dude reports back to the user.
    private static func runCommand(summary: String, language: String, script: String) async -> Outcome {
        if language == "applescript" || language == "osascript" {
            let (error, value) = runAppleScriptCapturing(script)
            if let error { return .failed("That didn't work: \(error)") }
            let out = trimForReport(value)
            return .done(out.isEmpty ? "Done — \(summary)" : out)
        }

        // Default: shell. Run off the main actor so a slow command can't freeze
        // the UI, and fold stderr into stdout so failures explain themselves.
        let result = await Task.detached { runShellSync(script) }.value
        let out = trimForReport(result.output)
        if !result.ok {
            return .failed(out.isEmpty ? "The command exited with an error." : out)
        }
        return .done(out.isEmpty ? "Done — \(summary)" : out)
    }

    /// Runs a zsh script, capturing stdout+stderr together. `nonisolated` so it
    /// can run on a detached (non-main) task. Reads the pipe fully *before*
    /// waiting on exit to avoid deadlocking on a full pipe buffer.
    nonisolated private static func runShellSync(_ script: String) -> (ok: Bool, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return (false, "couldn't start the command: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (proc.terminationStatus == 0, output)
    }

    /// Trim and cap command output so a chatty command doesn't blow up the bubble.
    nonisolated private static func trimForReport(_ s: String?) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 600 ? String(t.prefix(600)) + "…" : t
    }

    // MARK: - Calendar / Reminders (EventKit)

    private static func createEvent(title: String, start: String, end: String?, notes: String?) async -> Outcome {
        guard let startDate = ActionParsing.parseDate(start) else {
            return .failed("Couldn't read the start time “\(start)”.")
        }
        let endDate = end.flatMap(ActionParsing.parseDate) ?? startDate.addingTimeInterval(3600)

        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else {
            return .failed("I need Calendar access — enable Dude under Privacy & Security ▸ Calendars.")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            let fmt = DateFormatter(); fmt.dateFormat = "EEE MMM d, HH:mm"
            return .done("Added “\(title)” to your calendar for \(fmt.string(from: startDate)).")
        } catch {
            return .failed("Couldn't save the event: \(error.localizedDescription)")
        }
    }

    private static func createReminder(title: String, due: String?) async -> Outcome {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true else {
            return .failed("I need Reminders access — enable Dude under Privacy & Security ▸ Reminders.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due, let date = ActionParsing.parseDate(due) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
        }
        do {
            try store.save(reminder, commit: true)
            return .done("Set a reminder to “\(title)”.")
        } catch {
            return .failed("Couldn't save the reminder: \(error.localizedDescription)")
        }
    }

    // MARK: - Plumbing

    /// Runs an AppleScript. Returns `nil` on success, or an error message.
    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return "couldn't compile the script"
        }
        _ = script.executeAndReturnError(&errorDict)
        if let errorDict, let message = errorDict[NSAppleScript.errorMessage] as? String {
            return message
        }
        return nil
    }

    /// Like `runAppleScript` but also returns the script's result value (if any),
    /// so a `run_command` AppleScript can report what it found back to the user.
    private static func runAppleScriptCapturing(_ source: String) -> (error: String?, value: String?) {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return ("couldn't compile the script", nil)
        }
        let result = script.executeAndReturnError(&errorDict)
        if let errorDict, let message = errorDict[NSAppleScript.errorMessage] as? String {
            return (message, nil)
        }
        return (nil, result.stringValue)
    }

}
