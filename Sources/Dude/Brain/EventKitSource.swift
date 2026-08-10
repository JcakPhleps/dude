import EventKit
import Foundation

/// Reads Calendar events and Reminders via EventKit. Each call requests access
/// (macOS shows the prompt the first time); returns `nil` when access is
/// denied so the Brain can tell the user how to grant it.
enum EventKitSource {
    /// Upcoming events over the next `days` days, as display lines.
    /// `nil` = no Calendar access. `[]` = access granted, nothing scheduled.
    static func upcomingEvents(days: Int = 7) async -> [String]? {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return nil }

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)

        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM d, HH:mm"
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEE MMM d"

        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(20)
            .map { event in
                let when = event.isAllDay
                    ? "\(dayFmt.string(from: event.startDate)) (all day)"
                    : fmt.string(from: event.startDate)
                return "\(when) — \(event.title ?? "(untitled)")"
            }
    }

    /// Incomplete reminders, as display lines.
    /// `nil` = no Reminders access. `[]` = granted, nothing open.
    static func openReminders() async -> [String]? {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true else { return nil }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        // Map to strings inside the completion so no non-Sendable EKReminder
        // crosses the async boundary.
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d"
                let lines = (reminders ?? []).prefix(20).map { reminder -> String in
                    let title = reminder.title ?? "(untitled)"
                    if let due = reminder.dueDateComponents?.date {
                        return "\(title) — due \(fmt.string(from: due))"
                    }
                    return title
                }
                continuation.resume(returning: lines)
            }
        }
    }
}
