import AppKit
import SwiftUI

/// A borderless, transparent, always-on-top panel that floats the mascot over
/// everything.
///
/// `NSHostingView`'s `preferredContentSize` does NOT resize a borderless panel,
/// so instead the SwiftUI root reports its measured size and we size the window
/// ourselves — pinning the bottom-right corner so the bubble grows upward while
/// the mascot stays put. Draggable by its background.
@MainActor
final class PetPanel: NSPanel {
    /// The bottom-right point on screen the panel stays pinned to as it resizes.
    private var anchor: CGPoint?

    /// While Dude is striding across the screen we drive his origin ourselves;
    /// this flag keeps the resize/drag bookkeeping from fighting the animation.
    private var isWalking = false
    /// Set until the first real content measure lets us re-center on the idle spot.
    private var pendingHomePlacement = false
    private var walkTimer: Timer?
    private var walkStart = NSPoint.zero
    private var walkTarget = NSPoint.zero
    private var walkStep = 0
    private var walkSteps = 1
    private var walkCompletion: (() -> Void)?

    init(brain: Brain) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        let root = PetRootView(brain: brain, onResize: { [weak self] size in
            self?.resizeToFit(size)
        })
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        // Update the pin point when the user drags the panel.
        NotificationCenter.default.addObserver(
            self, selector: #selector(didMove),
            name: NSWindow.didMoveNotification, object: self
        )
    }

    override var canBecomeKey: Bool { true }

    /// Dude's fixed idle spot, given as a top-left **pixel** coordinate on the
    /// main display. Converted to Cocoa points at the display's scale.
    private static let idlePixel = CGPoint(x: 2502, y: 1680)

    /// The panel origin (bottom-left, Cocoa points) that puts Dude at `idlePixel`.
    private func idleOrigin() -> NSPoint? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main else { return nil }
        let scale = screen.backingScaleFactor
        let pointX = Self.idlePixel.x / scale
        let pointYFromTop = Self.idlePixel.y / scale
        // idlePixel marks where Dude should sit, so center the panel on it.
        let cocoaY = screen.frame.height - pointYFromTop
        return NSPoint(x: pointX - frame.width / 2, y: cocoaY - frame.height / 2)
    }

    /// Park Dude at his idle spot. At launch the SwiftUI content hasn't measured
    /// yet, so `frame.size` is still the placeholder — we place him now for a
    /// first approximation and set `pendingHomePlacement` so the first real
    /// `resizeToFit` re-centers him with the correct size.
    func moveToDefaultCorner() {
        pendingHomePlacement = true
        placeAtHome()
    }

    private func placeAtHome() {
        guard let origin = idleOrigin() else { return }
        setFrameOrigin(origin)
        anchor = CGPoint(x: frame.maxX, y: frame.minY)
    }

    // MARK: - Walking

    /// Slide the panel to `target` (a bottom-left origin) over a short eased
    /// animation, resuming once he's arrived.
    @MainActor
    func walkAsync(to target: NSPoint) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            walk(to: target) { cont.resume() }
        }
    }

    /// Stroll back to the idle spot.
    @MainActor
    func walkHomeAsync() async {
        guard let home = idleOrigin() else { return }
        await walkAsync(to: home)
        anchor = CGPoint(x: frame.maxX, y: frame.minY)
    }

    private func walk(to target: NSPoint, completion: @escaping () -> Void) {
        walkTimer?.invalidate()
        let start = frame.origin
        let distance = hypot(target.x - start.x, target.y - start.y)
        guard distance > 1 else { completion(); return }

        isWalking = true
        walkStart = start
        walkTarget = target
        walkStep = 0
        walkSteps = max(1, Int(min(2.0, max(0.5, distance / 700.0)) * 60.0)) // ~700 pt/s at 60fps
        walkCompletion = completion
        // Target/selector timer (not a block) so there's no @Sendable closure to
        // fight the panel's main-thread state.
        walkTimer = Timer.scheduledTimer(timeInterval: 1.0 / 60.0, target: self,
                                         selector: #selector(stepWalk), userInfo: nil, repeats: true)
    }

    @objc private func stepWalk() {
        walkStep += 1
        let p = min(1.0, Double(walkStep) / Double(walkSteps))
        let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2   // easeInOut
        setFrameOrigin(NSPoint(x: walkStart.x + (walkTarget.x - walkStart.x) * eased,
                               y: walkStart.y + (walkTarget.y - walkStart.y) * eased))
        guard p >= 1.0 else { return }
        walkTimer?.invalidate()
        walkTimer = nil
        isWalking = false
        let done = walkCompletion
        walkCompletion = nil
        done?()
    }

    private func resizeToFit(_ size: CGSize) {
        guard !isWalking else { return }
        guard size.width > 1, size.height > 1 else { return }
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 48
        let newSize = NSSize(width: ceil(size.width), height: ceil(min(size.height, maxHeight)))
        guard abs(newSize.width - frame.width) > 0.5 || abs(newSize.height - frame.height) > 0.5 else {
            return
        }
        setContentSize(newSize)
        // First real measure: now that the size is correct, re-center on the
        // idle spot (launch placement used the placeholder size).
        if pendingHomePlacement {
            pendingHomePlacement = false
            placeAtHome()
            return
        }
        // Re-pin the bottom-right corner so the mascot doesn't drift and the
        // window grows upward rather than off the bottom of the screen.
        if let anchor {
            setFrameOrigin(NSPoint(x: anchor.x - frame.width, y: anchor.y))
        }
    }

    @objc private func didMove() {
        guard !isWalking, let anchor else { return }
        let expected = NSPoint(x: anchor.x - frame.width, y: anchor.y)
        // Only treat this as a user drag (not our own re-pin) when the origin
        // differs from where re-pinning would have placed it.
        if frame.origin != expected {
            self.anchor = CGPoint(x: frame.maxX, y: frame.minY)
        }
    }
}
