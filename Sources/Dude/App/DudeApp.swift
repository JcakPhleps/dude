import SwiftUI

@main
struct DudeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Dude lives in a floating panel + status bar item managed by the
        // AppDelegate, so this scene stays empty.
        Settings { EmptyView() }
    }
}
