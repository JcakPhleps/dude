import AppKit
import ApplicationServices

/// Finds where an app's icon sits in the Dock, so Dude can stroll over to it.
///
/// The Dock exposes its icons through the Accessibility API (there's no public
/// geometry API), so this needs Accessibility permission. Without it — or if the
/// app isn't pinned/running in the Dock — `iconFrame` returns nil and Dude just
/// does the thing in place instead of walking.
@MainActor
enum DockLocator {

    /// Whether Dude is allowed to read the Dock's layout yet.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask for Accessibility, showing the system prompt if it hasn't been decided.
    @discardableResult
    static func requestTrust() -> Bool {
        // Literal of kAXTrustedCheckOptionPrompt — the C global is flagged as
        // non-concurrency-safe under Swift 6, and the key value is stable.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// The on-screen frame (Cocoa coords, bottom-left origin) of the Dock icon
    /// whose title matches `appName`, or nil if we can't find it.
    static func iconFrame(forAppNamed appName: String) -> CGRect? {
        guard isTrusted else { return nil }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard let list = firstChild(of: dockElement, role: kAXListRole),
              let items = children(of: list) else { return nil }

        let wanted = appName.lowercased()
        for item in items {
            guard let title = string(item, kAXTitleAttribute)?.lowercased() else { continue }
            guard title == wanted || title.hasPrefix(wanted) || wanted.hasPrefix(title) else { continue }
            guard let position = value(item, kAXPositionAttribute, .cgPoint, CGPoint.self),
                  let size = value(item, kAXSizeAttribute, .cgSize, CGSize.self) else { return nil }
            return cocoaRect(axTopLeft: position, size: size)
        }
        return nil
    }

    // MARK: - AX plumbing

    private static func firstChild(of element: AXUIElement, role: String) -> AXUIElement? {
        children(of: element)?.first { copyAttribute(element: $0, kAXRoleAttribute) as? String == role }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        copyAttribute(element: element, kAXChildrenAttribute) as? [AXUIElement]
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element: element, attribute) as? String
    }

    private static func copyAttribute(element: AXUIElement, _ attribute: String) -> AnyObject? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    /// Read an `AXValue` (a boxed CGPoint/CGSize) off an element.
    private static func value<T>(_ element: AXUIElement, _ attribute: String,
                                 _ type: AXValueType, _ as: T.Type) -> T? {
        guard let raw = copyAttribute(element: element, attribute) else { return nil }
        let axValue = raw as! AXValue
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(axValue, type, out) else { return nil }
        return out.pointee
    }

    /// AX geometry is top-left origin over the whole desktop; flip it into Cocoa's
    /// bottom-left origin using the primary screen's height.
    private static func cocoaRect(axTopLeft: CGPoint, size: CGSize) -> CGRect {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main)?.frame.height ?? 0
        let cocoaY = primaryHeight - axTopLeft.y - size.height
        return CGRect(x: axTopLeft.x, y: cocoaY, width: size.width, height: size.height)
    }
}
