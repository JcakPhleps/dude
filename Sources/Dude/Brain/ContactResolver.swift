import Contacts
import Foundation

/// Turns a human name ("Gavin", "Mom") into an actual iMessage handle (phone or
/// email), since the Messages AppleScript can only address a concrete handle.
///
/// If the string already looks like a handle (has a digit or an "@"), it's used
/// as-is. Needs Contacts access (`NSContactsUsageDescription`); the first lookup
/// triggers the macOS prompt.
enum ContactResolver {
    /// Best-effort resolve. Returns a handle to send to, or `nil` if no contact
    /// matched (the caller then reports that back instead of sending blind).
    static func handle(for recipient: String) async -> String? {
        let raw = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // Already a phone number or email — send straight to it.
        if raw.contains("@") || raw.contains(where: \.isNumber) { return raw }

        let store = CNContactStore()
        let granted: Bool = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { ok, _ in continuation.resume(returning: ok) }
        }
        guard granted else { return nil }

        let keys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: raw)
        guard let matches = try? store.unifiedContacts(matching: predicate, keysToFetch: keys),
              let contact = matches.first else {
            return nil
        }

        // Prefer a mobile number, else any number, else an email.
        if let mobile = contact.phoneNumbers.first(where: {
            $0.label == CNLabelPhoneNumberMobile || $0.label == CNLabelPhoneNumberiPhone
        }) {
            return mobile.value.stringValue
        }
        if let anyPhone = contact.phoneNumbers.first {
            return anyPhone.value.stringValue
        }
        return contact.emailAddresses.first.map { $0.value as String }
    }
}
