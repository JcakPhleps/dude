import AppKit
import Carbon.HIToolbox
import SwiftUI

extension Notification.Name {
    /// Posted from the status-bar menu to pop open the ask field.
    static let dudeOpenAsk = Notification.Name("dude.openAsk")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let memory = MemoryStore()
    private lazy var brain = Brain(memory: memory)
    private lazy var observer = Observer(memory: memory, brain: brain)
    private var hotKey: HotKeyManager?

    private var petPanel: PetPanel?
    private var statusItem: NSStatusItem?
    private var setupWindow: NSWindow?
    private var watchItem: NSMenuItem?
    private var readMessagesItem: NSMenuItem?

    private let observeDefaultsKey = "dude.observeEnabled"
    private let readMessagesKey = "dude.readMessages"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        setUpHotKey()
        showPet()

        // Resume background watching if it was on last time (default: on).
        let enabled = UserDefaults.standard.object(forKey: observeDefaultsKey) as? Bool ?? true
        if enabled { observer.start() }
        reflectWatchState()
        reflectReadMessages()

        // Nudge first-time users into setup.
        if memory.profile.isEmpty {
            openSetup()
        }
    }

    // MARK: - Pet

    private func showPet() {
        let panel = PetPanel(brain: brain)
        panel.moveToDefaultCorner()
        panel.orderFrontRegardless()
        petPanel = panel

        // Let Dude physically walk to an app's Dock icon before acting on it.
        brain.walkToApp = { [weak self] appName in
            guard let self, let panel = self.petPanel,
                  let icon = DockLocator.iconFrame(forAppNamed: appName) else { return false }
            let target = NSPoint(x: icon.midX - panel.frame.width / 2, y: icon.maxY + 6)
            await panel.walkAsync(to: target)
            return true
        }
        brain.walkHome = { [weak self] in
            await self?.petPanel?.walkHomeAsync()
        }
    }

    // MARK: - Status bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🙂"
        item.button?.toolTip = "dude"

        let menu = NSMenu()
        menu.addItem(withTitle: "Ask dude…", action: #selector(askDude), keyEquivalent: "")
        let watch = menu.addItem(withTitle: "Watch my screen", action: #selector(toggleWatch), keyEquivalent: "")
        watchItem = watch
        let readMsgs = menu.addItem(withTitle: "Read my Messages", action: #selector(toggleReadMessages), keyEquivalent: "")
        readMessagesItem = readMsgs
        menu.addItem(withTitle: "Allow access…", action: #selector(allowAccess), keyEquivalent: "")
        menu.addItem(withTitle: "Walk to apps (Accessibility)…", action: #selector(allowAccessibility), keyEquivalent: "")
        menu.addItem(withTitle: "Full Disk Access…", action: #selector(openFullDiskAccess), keyEquivalent: "")
        menu.addItem(withTitle: "Setup…", action: #selector(openSetup), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit dude", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleWatch() {
        observer.toggle()
        UserDefaults.standard.set(observer.isRunning, forKey: observeDefaultsKey)
        reflectWatchState()
    }

    /// Mirror the observer's on/off state into the menu checkmark and the
    /// status-bar face (👀 while watching).
    private func reflectWatchState() {
        watchItem?.state = observer.isRunning ? .on : .off
        statusItem?.button?.title = observer.isRunning ? "👀" : "🙂"
    }

    @objc private func toggleReadMessages() {
        let current = UserDefaults.standard.object(forKey: readMessagesKey) as? Bool ?? true
        UserDefaults.standard.set(!current, forKey: readMessagesKey)
        reflectReadMessages()
    }

    private func reflectReadMessages() {
        let on = UserDefaults.standard.object(forKey: readMessagesKey) as? Bool ?? true
        readMessagesItem?.state = on ? .on : .off
    }

    @objc private func allowAccess() {
        Task { @MainActor in
            let results = await PermissionsRequester.requestAll()
            let granted = results.filter(\.granted).count
            let alert = NSAlert()
            alert.messageText = "Access: \(granted)/\(results.count) granted"
            alert.informativeText = results.map { r in
                let mark = r.granted ? "✅" : "❌"
                return "\(mark) \(r.name)" + (r.granted ? "" : "  — \(r.note ?? "")")
            }.joined(separator: "\n")
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Open Privacy Settings")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Accessibility lets Dude read the Dock's layout so he can walk over to an
    /// app's icon. If it's already granted, say so; otherwise trigger the system
    /// prompt (and offer a deep-link in case it was denied before).
    @objc private func allowAccessibility() {
        if DockLocator.isTrusted {
            let alert = NSAlert()
            alert.messageText = "Already good to go"
            alert.informativeText = "Dude can walk over to apps in your Dock."
            alert.addButton(withTitle: "Nice")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        DockLocator.requestTrust()
        let alert = NSAlert()
        alert.messageText = "Turn on Accessibility for Dude"
        alert.informativeText = "So Dude can stroll over to an app's Dock icon before he works on it, enable Dude under Privacy & Security ▸ Accessibility."
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Open Accessibility Settings")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Global shortcut (⌃⌥D)

    private func setUpHotKey() {
        hotKey = HotKeyManager(
            keyCode: UInt32(kVK_ANSI_D),
            carbonModifiers: UInt32(controlKey | optionKey)
        ) { [weak self] in
            Task { @MainActor in self?.askDude() }
        }
    }

    @objc private func askDude() {
        petPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .dudeOpenAsk, object: nil)
    }

    @objc private func openSetup() {
        if let window = setupWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SetupView(memory: memory) { [weak self] in
            self?.setupWindow?.close()
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "dude · setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }
}
