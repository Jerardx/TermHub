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

    /// Handle a mouse-wheel event.
    ///
    /// If the running app captured the mouse (fullscreen alt-screen TUIs like
    /// Claude Code), forward the wheel to it as mouse button 4/5 — exactly what
    /// iTerm/Terminal.app do, which is *why* scrolling works inside Claude Code
    /// there. We only ever send genuine wheel buttons (64/65), never a click, so
    /// this can't synthesize a link click. Otherwise we scroll our own scrollback
    /// with scroll-lock. Shift forces local scrollback.
    func handleScrollWheel(_ event: NSEvent) -> Bool {
        let precise = event.hasPreciseScrollingDeltas
        let delta = precise ? event.scrollingDeltaY : event.deltaY
        guard delta != 0 else { return true }
        let lines = max(1, precise ? Int((abs(delta) / 10).rounded()) : Int(abs(delta)))
        let terminal = getTerminal()

        if terminal.mouseMode != .off && !event.modifierFlags.contains(.shift) {
            let button = delta > 0 ? 4 : 5
            let flags = event.modifierFlags
            let buttonFlags = terminal.encodeButton(
                button: button, release: false,
                shift: false, meta: flags.contains(.option), control: flags.contains(.control))
            let pt = convert(event.locationInWindow, from: nil)
            let dims = terminal.getDims()
            let cellW = bounds.width / CGFloat(max(1, dims.cols))
            let cellH = bounds.height / CGFloat(max(1, dims.rows))
            let col = max(0, min(dims.cols - 1, Int(pt.x / max(1, cellW))))
            let row = max(0, min(dims.rows - 1, Int((bounds.height - pt.y) / max(1, cellH))))
            for _ in 0..<min(lines, 8) {
                terminal.sendEvent(buttonFlags: buttonFlags, x: col, y: row)
            }
            return true
        }

        if delta > 0 { scrollUp(lines: lines) } else { scrollDown(lines: lines) }
        updateScrollLock()
        return true
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
    /// Notified whenever a session (re)starts, to re-anchor interval schedules.
    weak var scheduler: RestartScheduler?

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

    /// SwiftTerm's `scrollWheel` is `public` (not `open`), so it can't be
    /// overridden from our module. Catch scroll events app-side instead and let
    /// the hit terminal handle them (forward to the app when it captured the
    /// mouse, otherwise scroll our scrollback). Consuming the event also avoids
    /// SwiftTerm's own handler running on top of ours.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window,
                  let hit = window.contentView?.hitTest(event.locationInWindow) else { return event }
            var view: NSView? = hit
            while let cur = view {
                if let term = cur as? SessionTerminalView {
                    return term.handleScrollWheel(event) ? nil : event
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
        // A real initial frame so sessions started without a mounted pane (e.g.
        // created by an agent over the control socket) get a sane pty size;
        // panes resize it on mount anyway.
        let view = SessionTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
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
        scheduler?.noteStarted(session.id)

        let cmd = session.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cmd.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak view] in
                view?.send(txt: cmd + "\n")
            }
        }
    }

    // MARK: Actions

    /// (Re)start a session by id. If a live view exists it is torn down first;
    /// otherwise this acts as a first start for a session that hasn't been
    /// opened yet.
    func restart(_ id: UUID) {
        guard let session = appState?.session(id: id) else { return }
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

    func restartSelected() {
        guard let id = appState?.selectedSessionID else { return }
        restart(id)
    }

    /// Stop the process of a session by id (no-op if it was never started).
    ///
    /// `view.terminate()` closes the pty master, which reliably hangs up the
    /// shell (its SIGTERM alone is ignored by interactive shells) — but it also
    /// cancels SwiftTerm's process monitor, so `processTerminated` never fires.
    /// Update the session state ourselves or it would show "running" forever.
    func terminate(_ id: UUID) {
        guard let view = views[id] else { return }
        let wasRunning = appState?.session(id: id)?.state.isRunning ?? false
        view.terminate()
        guard wasRunning else { return }
        clearActivity(id)
        view.closeLog()
        appState?.session(id: id)?.state = .exited(0)
    }

    func terminateSelected() {
        guard let id = appState?.selectedSessionID else { return }
        terminate(id)
    }

    /// Whether a live terminal exists for the session (started at some point).
    func isStarted(_ id: UUID) -> Bool { views[id] != nil }

    /// Create + start the session's terminal if it hasn't been opened yet
    /// (used by the control socket so agent-created sessions run immediately,
    /// without waiting for a pane to mount them).
    func ensureStarted(_ id: UUID) {
        _ = view(for: id)
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
            // A restart replaces the view before the old process's termination
            // callback lands; ignore stale views so they can't overwrite the
            // fresh session's .running state.
            guard self.views[session.id] === view else { return }
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
