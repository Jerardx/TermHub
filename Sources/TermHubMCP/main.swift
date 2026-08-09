// termhub-mcp — a minimal MCP (Model Context Protocol) stdio server that
// proxies tool calls to the running TermHub app over its Unix control socket.
//
// No dependencies: MCP over stdio is newline-delimited JSON-RPC 2.0, and the
// app side is newline-delimited JSON too, so this is a thin translator.
//
// Register with Claude Code:
//   claude mcp add termhub -- /Applications/TermHub.app/Contents/MacOS/termhub-mcp

import Foundation

// MARK: - Plumbing

let stdout = FileHandle.standardOutput
let stderr = FileHandle.standardError

func logErr(_ s: String) {
    stderr.write(Data(("termhub-mcp: " + s + "\n").utf8))
}

func emit(_ payload: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    data.append(UInt8(ascii: "\n"))
    stdout.write(data)
}

func respond(id: Any, result: [String: Any]) {
    emit(["jsonrpc": "2.0", "id": id, "result": result])
}

func respondError(id: Any, code: Int, message: String) {
    emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

// MARK: - Control-socket client

/// Keep in sync with ControlServer.socketPath() in the app.
func socketPath() -> String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("TermHub/control.sock").path
}

let notRunningHint =
    "TermHub is not reachable. Make sure the TermHub app is running and " +
    "\"Enable Agent Control\" is turned on in TermHub → Settings."

var nextControlID = 0

struct CallFailure: Error, ExpressibleByStringLiteral {
    let message: String
    init(_ message: String) { self.message = message }
    init(stringLiteral value: String) { self.message = value }
}

/// One request/response round-trip over a fresh socket connection.
func callTermHub(method: String, params: [String: Any]) -> Result<Any, CallFailure> {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failure("socket() failed") }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = socketPath()
    let fits = path.withCString { cs -> Bool in
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let len = strlen(cs)
            guard len + 1 <= buf.count else { return false }
            memcpy(buf.baseAddress!, cs, len + 1)
            return true
        }
    }
    guard fits else { return .failure("socket path too long") }

    var tv = timeval(tv_sec: 15, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return .failure(CallFailure(notRunningHint)) }

    nextControlID += 1
    let request: [String: Any] = ["id": nextControlID, "method": method, "params": params]
    guard var data = try? JSONSerialization.data(withJSONObject: request) else {
        return .failure("failed to encode request")
    }
    data.append(UInt8(ascii: "\n"))
    let sentOK = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
        var offset = 0
        while offset < buf.count {
            let n = write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
    guard sentOK else { return .failure(CallFailure(notRunningHint)) }

    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while !response.contains(UInt8(ascii: "\n")) {
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return .failure(CallFailure(notRunningHint)) }
        response.append(contentsOf: chunk[0..<n])
        if response.count > 16_777_216 { return .failure("response too large") }
    }
    guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
        return .failure("malformed response from TermHub")
    }
    if let error = json["error"] as? String { return .failure(CallFailure(error)) }
    return .success(json["result"] ?? [:])
}

// MARK: - Tool definitions

let sessionRefDescription =
    "Session reference: a session title (e.g. \"backend\"), \"group/title\" if titles repeat, " +
    "or a session id from list_sessions."

let tools: [[String: Any]] = [
    [
        "name": "list_sessions",
        "description": "List all TermHub groups and terminal sessions with their status " +
            "(running / exited+exit code / not started), configured command, working directory, " +
            "and whether agent control is allowed for each session.",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
        "name": "create_group",
        "description": "Create a new (empty) session group in the TermHub sidebar.",
        "inputSchema": [
            "type": "object",
            "properties": ["name": ["type": "string", "description": "Group name"]],
            "required": ["name"],
        ],
    ],
    [
        "name": "create_session",
        "description": "Create a terminal session in a group and (by default) start it immediately. " +
            "The command is auto-typed into a login shell, so it also runs again on every restart.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "group": ["type": "string", "description": "Name of an existing group (see list_sessions; use create_group to add one)"],
                "title": ["type": "string", "description": "Session title shown in the sidebar"],
                "command": ["type": "string", "description": "Command to auto-run in the session, e.g. \"npm run dev\" (optional; empty = plain shell)"],
                "working_directory": ["type": "string", "description": "Directory to start the shell in (optional, defaults to home; ~ is expanded)"],
                "start": ["type": "boolean", "description": "Start the session right away (default true)"],
                "auto_start": ["type": "boolean", "description": "Also start this session automatically whenever the TermHub app launches (default false)"],
                "restart_every_hours": ["type": "integer", "description": "Automatically restart the session every N hours, 1–168 (optional)"],
                "restart_daily_at": ["type": "string", "description": "Automatically restart the session daily at \"HH:MM\" 24h local time (optional; ignored if restart_every_hours is set)"],
            ],
            "required": ["group", "title"],
        ],
    ],
    [
        "name": "restart_session",
        "description": "Restart a session: kill its shell (if running) and start it fresh, re-running its configured command. Also used to start a not-yet-started or exited session.",
        "inputSchema": [
            "type": "object",
            "properties": ["session": ["type": "string", "description": sessionRefDescription]],
            "required": ["session"],
        ],
    ],
    [
        "name": "stop_session",
        "description": "Stop a running session's process (the session stays in the sidebar and can be restarted).",
        "inputSchema": [
            "type": "object",
            "properties": ["session": ["type": "string", "description": sessionRefDescription]],
            "required": ["session"],
        ],
    ],
    [
        "name": "read_output",
        "description": "Read the last lines of a session's output log — use this to check what a process printed, diagnose why it failed, or monitor progress. ANSI escape codes are stripped by default.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "session": ["type": "string", "description": sessionRefDescription],
                "lines": ["type": "integer", "description": "How many trailing lines to return (default 100, max 2000)"],
                "raw": ["type": "boolean", "description": "Return raw output with ANSI escape codes (default false)"],
            ],
            "required": ["session"],
        ],
    ],
]

// MARK: - Result formatting

func textContent(_ text: String, isError: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["content": [["type": "text", "text": text]]]
    if isError { result["isError"] = true }
    return result
}

func formatResult(toolName: String, result: Any) -> String {
    guard let dict = result as? [String: Any] else { return "\(result)" }
    // read_output returns the log text itself; mutations return a message.
    if toolName == "read_output", let text = dict["text"] as? String { return text }
    if let message = dict["message"] as? String { return message }
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return "\(dict)"
}

// MARK: - JSON-RPC loop

func handle(_ message: [String: Any]) {
    let method = message["method"] as? String ?? ""
    let id = message["id"]

    // Notifications (no id) need no response.
    guard let id else { return }

    switch method {
    case "initialize":
        let params = message["params"] as? [String: Any]
        let requested = params?["protocolVersion"] as? String ?? "2025-06-18"
        respond(id: id, result: [
            "protocolVersion": requested,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "termhub", "version": "1.0.0"],
        ])
    case "ping":
        respond(id: id, result: [:])
    case "tools/list":
        respond(id: id, result: ["tools": tools])
    case "tools/call":
        let params = message["params"] as? [String: Any] ?? [:]
        guard let name = params["name"] as? String,
              tools.contains(where: { $0["name"] as? String == name }) else {
            respondError(id: id, code: -32602, message: "unknown tool")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch callTermHub(method: name, params: arguments) {
        case .success(let result):
            respond(id: id, result: textContent(formatResult(toolName: name, result: result)))
        case .failure(let failure):
            respond(id: id, result: textContent(failure.message, isError: true))
        }
    default:
        respondError(id: id, code: -32601, message: "method not found: \(method)")
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
        logErr("skipping malformed input line")
        continue
    }
    handle(json)
}
