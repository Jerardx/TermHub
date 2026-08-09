import SwiftUI
import AppKit

// MARK: - New / Edit session sheets

struct NewSessionDraft: Identifiable {
    let id = UUID()
    var groupID: UUID?
}

struct NewSessionSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let draft: NewSessionDraft

    @State private var title = ""
    @State private var command = ""
    @State private var workingDirectory = ""
    @State private var selectedGroupID: UUID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Session").font(.headline).padding()
            Divider()
            Form {
                TextField("Title", text: $title, prompt: Text("e.g. frontend dev"))
                Picker("Group", selection: $selectedGroupID) {
                    ForEach(appState.groups) { g in
                        Text(g.name).tag(g.id)
                    }
                }
                TextField("Command", text: $command, prompt: Text("optional, e.g. npm run dev"))
                HStack {
                    TextField("Working dir", text: $workingDirectory, prompt: Text("optional, defaults to home"))
                    Button("Choose…") { chooseDirectory() }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(appState.groups.isEmpty)
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear {
            selectedGroupID = draft.groupID ?? appState.groups.first?.id ?? UUID()
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }

    private func create() {
        guard let group = appState.groups.first(where: { $0.id == selectedGroupID })
            ?? appState.groups.first else { return }
        let finalTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? "shell" : title
        let session = TerminalSession(
            title: finalTitle,
            command: command,
            workingDirectory: workingDirectory
        )
        appState.addSession(to: group, session: session)
        dismiss()
    }
}

struct EditSessionSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Session").font(.headline).padding()
            Divider()
            Form {
                TextField("Title", text: $session.title)
                TextField("Command", text: $session.command, prompt: Text("auto-run on restart"))
                HStack {
                    TextField("Working dir", text: $session.workingDirectory)
                    Button("Choose…") { chooseDirectory() }
                }
                Text("Command and working dir apply the next time the session is restarted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Allow agent control (MCP)", isOn: $session.agentControlAllowed)
                Text("When off, agents can't restart, stop, or read this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            session.workingDirectory = url.path
        }
    }
}
