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

    // MARK: - Tool schema handed to Gemini

    /// Gemini `functionDeclarations`. Kept flat (string args only) so the
    /// round-trip stays simple and Sendable. `nonisolated` so the (non-actor)
    /// GeminiClient can build the request without hopping to the main actor.
    nonisolated static func functionDeclarations() -> [[String: Any]] {
        [
        [
            "name": "send_message",
            "description": "Send an iMessage/SMS to someone. Use for texting a person. Recipient may be a phone number, email, or exact contact name.",
            "parameters": [
                "type": "object",
                "properties": [
                    "recipient": ["type": "string", "description": "Phone number, email, or exact contact name"],
                    "body": ["type": "string", "description": "The message text"],
                ],
                "required": ["recipient", "body"],
            ],
        ],
        [
            "name": "send_email",
            "description": "Compose and send an email through the Mail app's default account.",
            "parameters": [
                "type": "object",
                "properties": [
                    "to": ["type": "string", "description": "Recipient email address"],
                    "subject": ["type": "string", "description": "Subject line"],
                    "body": ["type": "string", "description": "Email body text"],
                ],
                "required": ["to", "subject", "body"],
            ],
        ],
        [
            "name": "create_calendar_event",
            "description": "Add an event to the user's default calendar.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "Start time, ISO-8601 in local time, e.g. 2026-08-09T15:00"],
                    "end": ["type": "string", "description": "End time, ISO-8601 local. Optional; defaults to one hour after start."],
                    "notes": ["type": "string", "description": "Optional notes/description"],
                ],
                "required": ["title", "start"],
            ],
        ],
        [
            "name": "create_reminder",
            "description": "Add a reminder to the user's default Reminders list.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "due": ["type": "string", "description": "Optional due time, ISO-8601 local, e.g. 2026-08-09T09:00"],
                ],
                "required": ["title"],
            ],
        ],
        [
            "name": "control_spotify",
            "description": "Control the Spotify desktop app. command is one of: play, pause, next, previous, play_track. For play_track supply query (a song/artist to search and play).",
            "parameters": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "play | pause | next | previous | play_track"],
                    "query": ["type": "string", "description": "For play_track: what to play, e.g. 'Bad Guy Billie Eilish'"],
                ],
                "required": ["command"],
            ],
        ],
        [
            "name": "run_command",
            "description": """
            Do ANYTHING else on this Mac that the specific tools above don't cover \
            — organize files, open or quit apps, tweak settings, automate an app, \
            run a shell one-liner, etc. Provide a small script and a plain-English \
            summary. The user must approve it before it runs, so write exactly what \
            you'd run. Prefer reversible, least-destructive operations: move unwanted \
            files to the Trash (~/.Trash) rather than deleting them, don't use `sudo`, \
            and keep the script tightly scoped to what was asked.
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "description": "One short line telling the user plainly what this will do, e.g. 'Move all screenshots on your Desktop into a Screenshots folder.'"],
                    "language": ["type": "string", "description": "'shell' (zsh) or 'applescript'. Use applescript to drive/automate a specific app; shell for files and everything else. Defaults to shell."],
                    "script": ["type": "string", "description": "The exact script to run. For shell it's run with `zsh -lc`. Keep it to what the summary says."],
                    "app": ["type": "string", "description": "Optional: the name of the Mac app this acts on (e.g. 'Finder', 'Safari', 'Notes'), so Dude can stroll over to it. Omit if it's not about one particular app."],
                ],
                "required": ["summary", "script"],
            ],
        ],
        ]
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
    }

    /// Route a model tool call to the right handler.
    static func handle(name: String, args: [String: String]) async -> Outcome {
        switch name {
        case "send_message":
            guard let r = nonEmpty(args["recipient"]), let b = nonEmpty(args["body"]) else {
                return .failed("Missing recipient or body.")
            }
            return .staged(.message(recipient: r, body: b),
                           note: "Staged — waiting for the user to confirm before sending.")

        case "send_email":
            guard let to = nonEmpty(args["to"]), let s = nonEmpty(args["subject"]), let b = nonEmpty(args["body"]) else {
                return .failed("Missing to, subject, or body.")
            }
            return .staged(.email(to: to, subject: s, body: b),
                           note: "Staged — waiting for the user to confirm before sending.")

        case "create_calendar_event":
            guard let title = nonEmpty(args["title"]), let start = nonEmpty(args["start"]) else {
                return .failed("Missing title or start.")
            }
            return await createEvent(title: title, start: start, end: args["end"], notes: args["notes"])

        case "create_reminder":
            guard let title = nonEmpty(args["title"]) else { return .failed("Missing title.") }
            return await createReminder(title: title, due: args["due"])

        case "control_spotify":
            guard let command = nonEmpty(args["command"]) else { return .failed("Missing command.") }
            return spotify(command: command, query: args["query"])

        case "run_command":
            guard let summary = nonEmpty(args["summary"]), let script = nonEmpty(args["script"]) else {
                return .failed("Missing summary or script.")
            }
            let language = (nonEmpty(args["language"]) ?? "shell").lowercased()
            return .staged(.command(summary: summary, language: language,
                                    script: script, app: nonEmpty(args["app"])),
                           note: "Staged — waiting for the user to confirm before running it.")

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
            set targetBuddy to participant "\(esc(handle))" of targetService
            send "\(esc(body))" to targetBuddy
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
            set newMessage to make new outgoing message with properties {subject:"\(esc(subject))", content:"\(esc(body))", visible:true}
            tell newMessage
                make new to recipient at end of to recipients with properties {address:"\(esc(to))"}
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
            guard let q = nonEmpty(query) else { return .failed("Nothing to play — no query given.") }
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
        guard let startDate = parseDate(start) else {
            return .failed("Couldn't read the start time “\(start)”.")
        }
        let endDate = end.flatMap(parseDate) ?? startDate.addingTimeInterval(3600)

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
        if let due, let date = parseDate(due) {
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

    nonisolated private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    nonisolated private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Accept ISO-8601 (with or without seconds/zone) and a couple of plain
    /// "yyyy-MM-dd HH:mm" shapes, interpreted in the local time zone.
    nonisolated private static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = .current
            df.dateFormat = format
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}
