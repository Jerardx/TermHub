import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running via `swift run` (no .app bundle): make it a normal foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        Notifier.requestAuthorization()

        // Global ⌘⌥T toggles visibility from anywhere.
        HotKeyManager.shared.registerDefault {
            if NSApp.isActive {
                NSApp.hide(nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop every live child shell so pty children don't survive as orphans.
        TerminalController.shared?.terminateAll()
    }
}

@main
struct TermHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var controller = TerminalController()

    var body: some Scene {
        WindowGroup("TermHub") {
            ContentView(controller: controller)
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .commands {
            SessionCommands(appState: appState)
        }
    }
}

/// Menu-bar commands for keyboard navigation between sessions.
struct SessionCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("Session") {
            Button("Next Session") { appState.selectNext() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Session") { appState.selectPrevious() }
                .keyboardShortcut("[", modifiers: .command)
            Divider()
            ForEach(0..<9) { i in
                Button("Switch to Session \(i + 1)") { appState.select(index: i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
    }
}
