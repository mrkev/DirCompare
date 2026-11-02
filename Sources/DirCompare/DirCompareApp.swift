import AppKit
import SwiftUI

@main
struct DirCompareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("DirCompare") {
            ContentView()
                .frame(minWidth: 860, minHeight: 420)
        }
        .defaultSize(width: 1180, height: 720)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare executable (`swift run`) rather than the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        #if DEBUG
        DebugTools.scheduleSnapshotIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
