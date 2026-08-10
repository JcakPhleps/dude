import AppKit
import AVFoundation
import Contacts
import CoreGraphics
import EventKit
import Speech

/// Requests every permission Dude can use, in one shot, so the user grants them
/// up front instead of tripping prompts one at a time deep inside an action.
///
/// Anything that can't be requested through an API (Full Disk Access) is surfaced
/// with a note pointing at the right Settings pane.
@MainActor
enum PermissionsRequester {
    struct Outcome: Sendable {
        let name: String
        let granted: Bool
        let note: String?   // what to do if it isn't granted
    }

    /// Apps Dude drives via Apple Events. Their Automation prompt only appears
    /// when we actually send an event, so we ping the ones already running (so we
    /// don't launch a pile of apps).
    private static let automationTargets: [(name: String, bundleID: String)] = [
        ("Messages", "com.apple.MobileSMS"),
        ("Mail", "com.apple.mail"),
        ("Spotify", "com.spotify.client"),
        ("Music", "com.apple.Music"),
    ]

    static func requestAll() async -> [Outcome] {
        NSApp.activate(ignoringOtherApps: true)

        async let contacts = requestContacts()
        async let calendar = requestCalendar()
        async let reminders = requestReminders()
        async let mic = requestMic()
        async let speech = requestSpeech()

        var results = [await contacts, await calendar, await reminders, await mic, await speech]

        let screen = CGRequestScreenCaptureAccess()
        results.append(Outcome(name: "Screen Recording", granted: screen,
                               note: screen ? nil : "Turn on Dude under Privacy & Security ▸ Screen Recording."))

        results.append(contentsOf: requestAutomationForRunningTargets())

        let accessibility = DockLocator.requestTrust()
        results.append(Outcome(name: "Accessibility (walk to Dock apps)", granted: accessibility,
                               note: accessibility ? nil : "Turn on Dude under Privacy & Security ▸ Accessibility."))

        let fda = Permissions.hasFullDiskAccess
        results.append(Outcome(name: "Full Disk Access (Messages/Mail reading)", granted: fda,
                               note: fda ? nil : "Add Dude under Privacy & Security ▸ Full Disk Access, then relaunch."))
        return results
    }

    // MARK: - Individual requests

    private static func requestContacts() async -> Outcome {
        let granted: Bool
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await withCheckedContinuation { cont in
                // TCC fires this completion on a background XPC thread. The block
                // must be @Sendable (non-isolated) or Swift's main-actor
                // isolation check traps (EXC_BREAKPOINT) when it's called off-main.
                CNContactStore().requestAccess(for: .contacts) { @Sendable ok, _ in
                    cont.resume(returning: ok)
                }
            }
        default:
            granted = false
        }
        return Outcome(name: "Contacts", granted: granted,
                       note: granted ? nil : "Turn on Dude under Privacy & Security ▸ Contacts.")
    }

    private static func requestCalendar() async -> Outcome {
        let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        return Outcome(name: "Calendar", granted: granted,
                       note: granted ? nil : "Turn on Dude under Privacy & Security ▸ Calendars.")
    }

    private static func requestReminders() async -> Outcome {
        let granted = (try? await EKEventStore().requestFullAccessToReminders()) ?? false
        return Outcome(name: "Reminders", granted: granted,
                       note: granted ? nil : "Turn on Dude under Privacy & Security ▸ Reminders.")
    }

    private static func requestMic() async -> Outcome {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return Outcome(name: "Microphone", granted: granted,
                       note: granted ? nil : "Turn on Dude under Privacy & Security ▸ Microphone.")
    }

    private static func requestSpeech() async -> Outcome {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            // Same story as Contacts: this callback lands on a background thread,
            // so the block must be @Sendable to avoid a main-actor isolation trap.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                cont.resume(returning: status)
            }
        }
        let granted = status == .authorized
        return Outcome(name: "Speech Recognition", granted: granted,
                       note: granted ? nil : "Turn on Dude under Privacy & Security ▸ Speech Recognition.")
    }

    private static func requestAutomationForRunningTargets() -> [Outcome] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        var out: [Outcome] = []
        for target in automationTargets where running.contains(target.bundleID) {
            let error = runAppleScript("tell application \"\(target.name)\" to get name")
            out.append(Outcome(name: "Control \(target.name)", granted: error == nil,
                               note: error == nil ? nil : "Allow Dude to control \(target.name) under Privacy & Security ▸ Automation."))
        }
        return out
    }

    private static func runAppleScript(_ source: String) -> String? {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return "couldn't compile" }
        _ = script.executeAndReturnError(&errorDict)
        return (errorDict?[NSAppleScript.errorMessage] as? String)
    }
}
