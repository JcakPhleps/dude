import Carbon.HIToolbox
import AppKit

/// Registers a system-wide keyboard shortcut via the Carbon Hot Key API — which,
/// unlike a global NSEvent monitor, needs no Accessibility permission. Fires
/// `onFire` on the main run loop whenever the combo is pressed.
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onFire: () -> Void

    /// - Parameters:
    ///   - keyCode: a Carbon virtual key code (e.g. `kVK_ANSI_D`).
    ///   - carbonModifiers: OR'd Carbon modifier masks (e.g. `controlKey | optionKey`).
    init?(keyCode: UInt32, carbonModifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().onFire()
                return noErr
            },
            1, &eventType, selfPtr, &eventHandler
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x44_55_44_45), id: 1) // 'DUDE'
        let registerStatus = RegisterEventHotKey(
            keyCode, carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
