import AppKit
import SwiftTerm

/// A SwiftTerm local-process view that remembers which session it belongs to,
/// reports output activity (for the "unread"/pulse indicators), and mirrors all
/// pty output to a log file so the full history is recoverable even after a
/// full-screen (alternate-buffer) TUI clears the visible scrollback.
final class SessionTerminalView: LocalProcessTerminalView {
    var sessionID: UUID = UUID()
    var onActivity: (() -> Void)?
    /// Open file handle the raw pty output is appended to (nil = not logging).
    var logHandle: FileHandle?

    /// Scroll-lock: while the user is scrolled up into history we *hold* new
    /// output instead of feeding it to the terminal, because SwiftTerm snaps the
    /// viewport to the bottom on every new line (its `userScrolling` guard is
    /// internal and never set, so we can't ask it not to). Held bytes are still
    /// logged and still flagged as activity; they're flushed when the user
    /// scrolls back to the bottom. This is the classic terminal "scroll lock".
    private(set) var isScrollLocked = false
    private var heldOutput: [UInt8] = []
    private let heldCap = 8_000_000 // bytes; flush+resume if a parked view fills up

    public override func dataReceived(slice: ArraySlice<UInt8>) {
        if let logHandle { try? logHandle.write(contentsOf: Data(slice)) }
        if isScrollLocked {
            heldOutput.append(contentsOf: slice)
            if heldOutput.count > heldCap { unlockScrollAndFlush() }
            onActivity?()
            return
        }
        super.dataReceived(slice: slice)
        onActivity?()
    }

    /// Freeze the viewport (called once the user scrolls off the bottom).
    func lockScroll() { isScrollLocked = true }

    /// Resume live output, feeding everything buffered while locked.
    func unlockScrollAndFlush() {
        isScrollLocked = false
        guard !heldOutput.isEmpty else { return }
        let data = heldOutput
        heldOutput.removeAll(keepingCapacity: false)
        super.dataReceived(slice: data[...]) // [UInt8] slice == ArraySlice<UInt8>
    }

    /// After a user scroll: lock when parked in history, unlock+flush at bottom.
    func updateScrollLock() {
        guard canScroll else { unlockScrollAndFlush(); return }
        if scrollPosition >= 0.999 { unlockScrollAndFlush() } else { lockScroll() }
    }

    /// Flush and detach the log file (on restart/stop/exit/teardown).
    func closeLog() {
        try? logHandle?.synchronize()
        try? logHandle?.close()
        logHandle = nil
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

    /// Weak handle so `AppDelegate.applicationWillTerminate` can stop every child
    /// shell on quit (otherwise pty children can survive as orphans).
    private(set) static weak var shared: TerminalController?

    private var views: [UUID: SessionTerminalView] = [:]
    private weak var appState: AppState?

    /// Per-session timers that switch `isActive` back off once output goes quiet.
    private var activityTimers: [UUID: DispatchWorkItem] = [:]
    /// How long after the last output a session is still considered "active".
    private let activityFade: TimeInterval = 1.8
    /// Normal-buffer scrollback kept per session so you can scroll back far.
    private let scrollbackLines = 10_000

    /// Local monitor that fixes mouse-wheel scrolling (see `installScrollMonitor`).
    private var scrollMonitor: Any?

    func attach(_ appState: AppState) {
        self.appState = appState
        Self.shared = self
        installScrollMonitor()
    }

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    /// SwiftTerm's `scrollWheel` only reads the legacy `event.deltaY`, which is 0
    /// for precise-scrolling devices (trackpads, Magic Mouse, many modern mice),
    /// so the wheel does nothing there while click-drag selection still scrolls.
    /// Its `scrollWheel` is `public` (not `open`), so we can't override it — catch
    /// scroll events app-side instead and drive the hit terminal ourselves.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window,
                  let hit = window.contentView?.hitTest(event.locationInWindow) else { return event }
            var view: NSView? = hit
            while let cur = view {
                if let term = cur as? SessionTerminalView {
                    let precise = event.hasPreciseScrollingDeltas
                    let delta = precise ? event.scrollingDeltaY : event.deltaY
                    if delta != 0 {
                        let lines = precise
                            ? max(1, Int((abs(delta) / 10).rounded()))
                            : max(1, Int(abs(delta)))
                        if delta > 0 { term.scrollUp(lines: lines) } else { term.scrollDown(lines: lines) }
                        term.updateScrollLock()
                    }
                    return nil // consume so SwiftTerm's broken handler doesn't also run
                }
                view = cur.superview
            }
            return event
        }
    }

    // MARK: Session log files

    /// Directory holding one raw-output log per session.
    private func logsDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("TermHub/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Log file URL for a session (raw terminal output, includes escape codes —
    /// view with `less -R` / `cat`).
    func logURL(for id: UUID) -> URL {
        logsDir().appendingPathComponent("\(id.uuidString).log")
    }

    /// Truncate and open the session's log file, returning a handle to append to.
    private func openLog(for id: UUID) -> FileHandle? {
        let url = logURL(for: id)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }

    /// Drop terminals for sessions that no longer exist. Terminals for live
    /// sessions are created (and started) lazily by `view(for:)` when a pane
    /// first mounts them, so unopened sessions stay `.notStarted` (gray).
    func sync() {
        guard let appState else { return }
        let wanted = Set(appState.allSessions.map(\.id))
        for (id, view) in views where !wanted.contains(id) {
            clearActivity(id)
            view.closeLog()
            view.terminate()
            view.removeFromSuperview()
            views.removeValue(forKey: id)
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
            // Muted sessions stay quiet: no unread dot, no activity pulse.
            guard !session.isMuted else { return }
            if self.appState?.selectedSessionID != session.id {
                session.hasUnread = true
            }
            self.markActive(session)
        }
        views[session.id] = view
        start(session: session, in: view)
        return view
    }

    /// Mark a session as actively producing output and (re)arm its fade timer.
    private func markActive(_ session: TerminalSession) {
        session.isActive = true
        activityTimers[session.id]?.cancel()
        let id = session.id
        let work = DispatchWorkItem { [weak self, weak session] in
            session?.isActive = false
            self?.activityTimers[id] = nil
        }
        activityTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + activityFade, execute: work)
    }

    /// Stop the activity pulse immediately (restart/stop/exit/removal).
    private func clearActivity(_ id: UUID) {
        activityTimers[id]?.cancel()
        activityTimers[id] = nil
        appState?.session(id: id)?.isActive = false
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
        // Keep a long scrollback and mirror output to a log file so history is
        // recoverable even after a full-screen TUI (alt buffer has no scrollback).
        view.getTerminal().changeScrollback(scrollbackLines)
        view.closeLog()
        view.logHandle = openLog(for: session.id)
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
              let session = appState?.session(id: id) else { return }
        // If a live view exists, tear it down first; otherwise this acts as a
        // first start for a session that hasn't been opened yet.
        if let view = views[id] {
            clearActivity(id)
            view.closeLog()
            view.terminate()
            view.removeFromSuperview()
            views.removeValue(forKey: id)
        }
        _ = makeTerminal(for: session)
        revision &+= 1 // tell panes to remount the fresh view
    }

    func terminateSelected() {
        guard let id = appState?.selectedSessionID, let view = views[id] else { return }
        view.terminate()
    }

    /// Stop every live child shell. Called on app quit so pty children don't
    /// survive as orphans.
    func terminateAll() {
        for (_, view) in views {
            view.closeLog()
            view.terminate()
        }
    }

    /// Scroll actions the View menu / keyboard shortcuts drive on the focused
    /// terminal (works even when the mouse wheel keeps getting snapped to the
    /// bottom by a continuously-repainting TUI).
    enum ScrollAction { case pageUp, pageDown, lineUp, lineDown, top, bottom }

    /// Current scroll position (0…1, 1 == bottom), whether the session can
    /// scroll, and whether output is currently parked (scroll-locked) — drives
    /// the on-screen scroll indicator.
    func scrollInfo(for id: UUID) -> (position: Double, canScroll: Bool, locked: Bool)? {
        guard let view = views[id] else { return nil }
        return (view.scrollPosition, view.canScroll, view.isScrollLocked)
    }

    func scrollSelected(_ action: ScrollAction) {
        guard let id = appState?.selectedSessionID, let view = views[id] else { return }
        let bigJump = 1_000_000 // clamped internally to the buffer bounds
        switch action {
        case .pageUp:   view.pageUp()
        case .pageDown: view.pageDown()
        case .lineUp:   view.scrollUp(lines: 3)
        case .lineDown: view.scrollDown(lines: 3)
        case .top:      view.scrollUp(lines: bigJump)
        case .bottom:   view.scrollDown(lines: bigJump)
        }
        view.updateScrollLock()
    }

    /// Send a line (a trailing newline is added) to each of the given sessions.
    func broadcast(_ command: String, to ids: [UUID]) {
        let line = command + "\n"
        for id in ids {
            views[id]?.send(txt: line)
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let view = source as? SessionTerminalView else { return }
        let code = exitCode ?? 0
        Task { @MainActor [weak self] in
            guard let self, let session = self.appState?.session(id: view.sessionID) else { return }
            self.clearActivity(session.id)
            view.closeLog()
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
