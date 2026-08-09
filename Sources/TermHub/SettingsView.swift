import SwiftUI
import AppKit

/// App settings (⌘,) — currently just the agent-control (MCP) master switch.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    /// Bundled MCP proxy path (nil when running unbundled via `swift run`).
    private var mcpBinaryPath: String? {
        let path = Bundle.main.bundlePath + "/Contents/MacOS/termhub-mcp"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private var registerCommand: String {
        let bin = mcpBinaryPath ?? "<path-to>/termhub-mcp"
        return "claude mcp add termhub -- \"\(bin)\""
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Agent Control (MCP)", isOn: $appState.agentControlEnabled)
                Text("Lets AI agents manage TermHub over a local socket: list sessions, " +
                     "create groups and sessions, restart/stop them, and read their output. " +
                     "Individual sessions can opt out via “Allow Agent Control” in their context menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if appState.agentControlEnabled {
                Section("Connect Claude Code") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(registerCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(registerCommand, forType: .string)
                        }
                    }
                    if mcpBinaryPath == nil {
                        Text("Running unbundled — build the app with scripts/make-app.sh, or point " +
                             "the command at .build/<config>/termhub-mcp.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}
