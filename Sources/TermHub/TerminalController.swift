import AppKit
import SwiftTerm

/// A SwiftTerm local-process view that remembers which session it belongs to
/// and reports output activity (for the "unread" indicator).
final class SessionTerminalView: LocalProcessTerminalView {
    var sessionID: UUID = UUID()
    var onActivity: (() -> Void)?

    public override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onActivity?()
    }
}

/// Owns the live terminal views and keeps their processes running.
///
/// Views are *vended* to SwiftUI panes (`TerminalPaneView`), which mount them
/// into the layout. A terminal's pty keeps running even while its view is not
/// mounted anywhere, so background sessions stay alive across any split layout.
@MainActor
final class TerminalController: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    /// Bumped when a terminal view is replaced (e.g. restart) so panes remount it.
    @Published private(set) var revision = 0

    private var views: [UUID: SessionTerminalView] = [:]
    private weak var appState: AppState?

    func attach(_ appState: AppState) {
        self.appState = appState
    }

    /// Ensure a (started) terminal exists for every session; drop deleted ones.
    func sync() {
        guard let appState else { return }
        let wanted = Set(appState.allSessions.map(\.id))
        for (id, view) in views where !wanted.contains(id) {
            view.terminate()
            view.removeFromSuperview()
            views.removeValue(forKey: id)
        }
        for session in appState.allSessions where views[session.id] == nil {
            _ = makeTerminal(for: session)
        }
    }

    /// The live terminal view for a session, creating + starting it if needed.
    func view(for id: UUID) -> SessionTerminalView? {
        if let view = views[id] { return view }
        guard let session = appState?.session(id: id) else { return nil }
        return makeTerminal(for: session)
    }

    @discardableResult
    private func makeTerminal(for session: TerminalSession) -> SessionTerminalView {
        let view = SessionTerminalView(frame: .zero)
        view.sessionID = session.id
        view.processDelegate = self
        view.onActivity = { [weak self, weak session] in
            guard let self, let session else { return }
            if self.appState?.selectedSessionID != session.id {
                session.hasUnread = true
            }
        }
        views[session.id] = view
        start(session: session, in: view)
        return view
    }

    private func start(session: TerminalSession, in view: SessionTerminalView) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let cwd = session.workingDirectory.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : (session.workingDirectory as NSString).expandingTildeInPath
        let shellName = (shell as NSString).lastPathComponent

        view.startProcess(
            executable: shell,
            args: ["-l"],
            environment: nil,
            execName: "-\(shellName)",
            currentDirectory: cwd
        )
        session.state = .running
        session.hasUnread = false

        let cmd = session.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cmd.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak view] in
                view?.send(txt: cmd + "\n")
            }
        }
    }

    // MARK: Actions

    func restartSelected() {
        guard let id = appState?.selectedSessionID,
              let session = appState?.session(id: id),
              let view = views[id] else { return }
        view.terminate()
        view.removeFromSuperview()
        views.removeValue(forKey: id)
        _ = makeTerminal(for: session)
        revision &+= 1 // tell panes to remount the fresh view
    }

    func terminateSelected() {
        guard let id = appState?.selectedSessionID, let view = views[id] else { return }
        view.terminate()
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let view = source as? SessionTerminalView else { return }
        let code = exitCode ?? 0
        Task { @MainActor [weak self] in
            guard let self, let session = self.appState?.session(id: view.sessionID) else { return }
            session.state = .exited(code)
            let isForeground = NSApp.isActive && self.appState?.selectedSessionID == session.id
            if !isForeground {
                Notifier.post(
                    title: code == 0 ? "Session finished" : "Session failed",
                    body: "\(session.title) exited with code \(code)"
                )
                if self.appState?.selectedSessionID != session.id {
                    session.hasUnread = true
                }
            }
        }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
