import Foundation
import Combine

/// Local control socket for agents (MCP).
///
/// Listens on a Unix domain socket in the app-support dir and answers
/// newline-delimited JSON requests: `{"id":1,"method":"list_sessions","params":{…}}`
/// → `{"id":1,"result":…}` or `{"id":1,"error":"…"}`. The `termhub-mcp`
/// executable proxies MCP tool calls to this socket.
///
/// Socket I/O runs on a private queue; every request is handled on the
/// MainActor through `AppState`/`TerminalController` so the usual persistence
/// and pane reconciliation apply. The server only runs while the master
/// "agent control" toggle is on, and per-session `agentControlAllowed` gates
/// restart/stop/read of individual sessions.
final class ControlServer: ObservableObject {
    /// Weak handle so `AppDelegate.applicationWillTerminate` can remove the
    /// socket file on quit.
    private(set) static weak var shared: ControlServer?

    private weak var appState: AppState?
    private weak var controller: TerminalController?

    private let queue = DispatchQueue(label: "termhub.control-socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var cancellable: AnyCancellable?

    /// Socket path shared with `termhub-mcp` (keep in sync with TermHubMCP/main.swift).
    static func socketPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("TermHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("control.sock").path
    }

    @MainActor
    func attach(appState: AppState, controller: TerminalController) {
        self.appState = appState
        self.controller = controller
        Self.shared = self
        cancellable = appState.$agentControlEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.start() } else { self?.stop() }
            }
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    /// Synchronous teardown for app quit (removes the socket file).
    func shutdownNow() {
        queue.sync { self.stopOnQueue() }
    }

    // MARK: - Socket plumbing (on `queue`)

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    private func startOnQueue() {
        guard listenFD < 0 else { return }
        let path = Self.socketPath()
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("TermHub: control socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let fits = path.withCString { cs -> Bool in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let len = strlen(cs)
                guard len + 1 <= buf.count else { return false }
                memcpy(buf.baseAddress!, cs, len + 1)
                return true
            }
        }
        guard fits else {
            NSLog("TermHub: control socket path too long: \(path)")
            close(fd)
            return
        }

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            NSLog("TermHub: control bind/listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(path)
            return
        }
        chmod(path, 0o600) // owner-only, same as the config files

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        acceptSource = source
        NSLog("TermHub: agent control socket listening at \(path)")
    }

    private func stopOnQueue() {
        for (_, conn) in connections { closeConnection(conn) }
        connections.removeAll()
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
            unlink(Self.socketPath())
            NSLog("TermHub: agent control socket stopped")
        }
    }

    private func acceptConnection() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let conn = Connection(fd: fd, source: source)
        connections[fd] = conn
        source.setEventHandler { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.readAvailable(conn)
        }
        source.resume()
    }

    private func closeConnection(_ conn: Connection) {
        conn.source.cancel()
        close(conn.fd)
        connections.removeValue(forKey: conn.fd)
    }

    private func readAvailable(_ conn: Connection) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(conn.fd, &chunk, chunk.count)
        guard n > 0 else {
            closeConnection(conn)
            return
        }
        conn.buffer.append(contentsOf: chunk[0..<n])
        // Guard against a runaway client (no request line is anywhere near 1 MB).
        if conn.buffer.count > 1_048_576 {
            closeConnection(conn)
            return
        }
        while let nl = conn.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = conn.buffer[conn.buffer.startIndex..<nl]
            conn.buffer.removeSubrange(conn.buffer.startIndex...nl)
            handleLine(Data(lineData), on: conn)
        }
    }

    private func handleLine(_ data: Data, on conn: Connection) {
        guard !data.isEmpty else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            send(["error": "malformed request (expected one JSON object per line with a \"method\")"], on: conn)
            return
        }
        let reqID = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]
        let fd = conn.fd
        Task { @MainActor [weak self] in
            guard let self else { return }
            var response: [String: Any]
            do {
                response = ["result": try self.dispatch(method: method, params: params)]
            } catch let err as ControlError {
                response = ["error": err.message]
            } catch {
                response = ["error": "\(error)"]
            }
            if let reqID { response["id"] = reqID }
            self.queue.async {
                guard let conn = self.connections[fd] else { return }
                self.send(response, on: conn)
            }
        }
    }

    private func send(_ payload: [String: Any], on conn: Connection) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buf.count {
                let n = write(conn.fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    // MARK: - Request handling (MainActor)

    struct ControlError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    @MainActor
    private func dispatch(method: String, params: [String: Any]) throws -> Any {
        guard let appState, let controller else { throw ControlError("app is not ready yet") }
        guard appState.agentControlEnabled else {
            throw ControlError("Agent control is disabled in TermHub settings")
        }
        switch method {
        case "list_sessions":   return listSessions(appState)
        case "create_group":    return try createGroup(appState, params)
        case "create_session":  return try createSession(appState, controller, params)
        case "restart_session": return try restartSession(appState, controller, params)
        case "stop_session":    return try stopSession(appState, controller, params)
        case "read_output":     return try readOutput(appState, controller, params)
        default:
            throw ControlError("unknown method \"\(method)\"")
        }
    }

    @MainActor
    private func listSessions(_ appState: AppState) -> Any {
        let groups: [[String: Any]] = appState.groups.map { g in
            [
                "id": g.id.uuidString,
                "name": g.name,
                "sessions": g.sessions.map { s -> [String: Any] in
                    var info: [String: Any] = [
                        "id": s.id.uuidString,
                        "title": s.title,
                        "command": s.command,
                        "working_directory": s.workingDirectory,
                        "agent_control": s.agentControlAllowed,
                        "unread": s.hasUnread,
                        "auto_start": s.autoStart,
                    ]
                    if let schedule = s.restartSchedule {
                        info["restart_schedule"] = schedule.label
                    }
                    switch s.state {
                    case .notStarted:
                        info["status"] = "not_started"
                    case .running:
                        info["status"] = "running"
                    case .exited(let code):
                        info["status"] = "exited"
                        info["exit_code"] = Int(code)
                    }
                    return info
                },
            ]
        }
        return ["groups": groups]
    }

    @MainActor
    private func createGroup(_ appState: AppState, _ params: [String: Any]) throws -> Any {
        guard let name = (params["name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            throw ControlError("\"name\" is required")
        }
        if appState.groups.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ControlError("group \"\(name)\" already exists")
        }
        let g = appState.addGroup(name: name)
        return ["message": "created group \"\(name)\"", "id": g.id.uuidString]
    }

    @MainActor
    private func createSession(_ appState: AppState, _ controller: TerminalController,
                               _ params: [String: Any]) throws -> Any {
        guard let title = (params["title"] as? String)?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty else {
            throw ControlError("\"title\" is required")
        }
        guard let groupName = (params["group"] as? String)?.trimmingCharacters(in: .whitespaces),
              !groupName.isEmpty else {
            throw ControlError("\"group\" is required (use list_sessions to see groups, create_group to add one)")
        }
        guard let group = resolveGroup(appState, named: groupName) else {
            let names = appState.groups.map { "\"\($0.name)\"" }.joined(separator: ", ")
            throw ControlError("group \"\(groupName)\" not found (existing: \(names)); use create_group first")
        }
        var schedule: RestartSchedule?
        if let hours = params["restart_every_hours"] as? Int {
            guard (1...168).contains(hours) else { throw ControlError("\"restart_every_hours\" must be 1–168") }
            schedule = .every(hours: hours)
        } else if let daily = params["restart_daily_at"] as? String {
            let parts = daily.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
                throw ControlError("\"restart_daily_at\" must be \"HH:MM\" (24h)")
            }
            schedule = .daily(hour: parts[0], minute: parts[1])
        }
        // Agent-created sessions are agent-controllable by design.
        let session = TerminalSession(
            title: title,
            command: params["command"] as? String ?? "",
            workingDirectory: params["working_directory"] as? String ?? "",
            agentControlAllowed: true,
            autoStart: params["auto_start"] as? Bool ?? false,
            restartSchedule: schedule
        )
        // Don't steal the user's focus for agent-created sessions.
        appState.addSession(to: group, session: session, select: false)
        let start = params["start"] as? Bool ?? true
        if start { controller.ensureStarted(session.id) }
        return [
            "message": "created session \"\(title)\" in \"\(group.name)\"" + (start ? " (started)" : ""),
            "id": session.id.uuidString,
        ]
    }

    @MainActor
    private func restartSession(_ appState: AppState, _ controller: TerminalController,
                                _ params: [String: Any]) throws -> Any {
        let session = try resolveControllableSession(appState, params)
        controller.restart(session.id)
        return ["message": "restarted \"\(session.title)\""]
    }

    @MainActor
    private func stopSession(_ appState: AppState, _ controller: TerminalController,
                             _ params: [String: Any]) throws -> Any {
        let session = try resolveControllableSession(appState, params)
        guard controller.isStarted(session.id), session.state.isRunning else {
            throw ControlError("session \"\(session.title)\" is not running")
        }
        controller.terminate(session.id)
        return ["message": "stopped \"\(session.title)\""]
    }

    @MainActor
    private func readOutput(_ appState: AppState, _ controller: TerminalController,
                            _ params: [String: Any]) throws -> Any {
        let session = try resolveControllableSession(appState, params)
        let lines = min(max(params["lines"] as? Int ?? 100, 1), 2000)
        let raw = params["raw"] as? Bool ?? false
        let url = controller.logURL(for: session.id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ControlError("no output log yet for \"\(session.title)\" (session was never started)")
        }
        let text = Self.tail(of: url, lines: lines, stripANSI: !raw)
        return ["text": text, "session": session.title]
    }

    // MARK: - Name resolution

    @MainActor
    private func resolveGroup(_ appState: AppState, named name: String) -> SessionGroup? {
        appState.groups.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? appState.groups.first { $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Resolve `params["session"]` — a UUID, a "group/title" path, or a bare
    /// title — and enforce the per-session agent-control toggle.
    @MainActor
    private func resolveControllableSession(_ appState: AppState,
                                            _ params: [String: Any]) throws -> TerminalSession {
        guard let ref = (params["session"] as? String)?.trimmingCharacters(in: .whitespaces),
              !ref.isEmpty else {
            throw ControlError("\"session\" is required (a title, \"group/title\", or id from list_sessions)")
        }
        let session = try resolveSession(appState, ref: ref)
        guard session.agentControlAllowed else {
            throw ControlError("agent control is disabled for session \"\(session.title)\" (the user turned it off)")
        }
        return session
    }

    @MainActor
    private func resolveSession(_ appState: AppState, ref: String) throws -> TerminalSession {
        if let uuid = UUID(uuidString: ref), let s = appState.session(id: uuid) { return s }
        // "group/title" path form.
        if let slash = ref.firstIndex(of: "/") {
            let groupName = String(ref[..<slash]).trimmingCharacters(in: .whitespaces)
            let title = String(ref[ref.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
            if let group = resolveGroup(appState, named: groupName) {
                let matches = group.sessions.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame }
                if matches.count == 1 { return matches[0] }
                if matches.count > 1 {
                    throw ControlError("several sessions in \"\(group.name)\" are titled \"\(title)\"; use an id from list_sessions")
                }
            }
        }
        // Bare title across all groups.
        let matches = appState.allSessions.filter { $0.title.caseInsensitiveCompare(ref) == .orderedSame }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw ControlError("several sessions are titled \"\(ref)\"; use \"group/title\" or an id from list_sessions")
        }
        throw ControlError("session \"\(ref)\" not found (use list_sessions)")
    }

    // MARK: - Log tail + ANSI stripping

    /// Read the last `lines` lines of a raw pty log, optionally stripping ANSI
    /// escape sequences and resolving carriage-return overwrites (progress bars).
    static func tail(of url: URL, lines: Int, stripANSI: Bool) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 1_048_576 // plenty for 2000 lines even with escapes
        let offset = size > window ? size - window : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        if stripANSI { text = strippingANSI(text) }
        // Normalize CRLF first — Swift treats "\r\n" as a single grapheme, so
        // neither split(separator: "\n") nor lastIndex(of: "\r") would see it.
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var out = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            // Keep only what survives carriage-return overwrites.
            guard let cr = line.lastIndex(of: "\r") else { return String(line) }
            return String(line[line.index(after: cr)...])
        }
        if out.count > lines { out.removeFirst(out.count - lines) }
        return out.joined(separator: "\n")
    }

    private static let ansiPatterns: [NSRegularExpression] = {
        [
            "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)?",  // OSC (title, hyperlinks…)
            "\u{1B}[PX^_][^\u{1B}]*(\u{1B}\\\\)?",            // DCS/SOS/PM/APC strings
            "\u{1B}\\[[0-9;?:<=>]*[ -/]*[@-~]",               // CSI (colors, cursor…)
            "\u{1B}[@-Z\\\\-_]",                              // two-char ESC sequences
            "\u{1B}[()][0-9A-Za-z]",                          // charset selection
            "[\u{00}-\u{08}\u{0B}\u{0C}\u{0E}-\u{1F}\u{7F}]", // stray control chars (keeps \t\n\r)
        ].compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func strippingANSI(_ input: String) -> String {
        var s = input
        for re in ansiPatterns {
            s = re.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s
    }
}
