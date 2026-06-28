import SwiftUI

// MARK: - Status color

extension SessionState {
    var indicatorColor: Color {
        switch self {
        case .notStarted: return .gray
        case .running: return .green
        case .exited(let code): return code == 0 ? .secondary : .red
        }
    }
}

// MARK: - Terminal pane (mounts a controller-owned terminal view)

struct TerminalPaneView: NSViewRepresentable {
    @ObservedObject var controller: TerminalController
    let sessionID: UUID
    let isFocused: Bool

    func makeNSView(context: Context) -> NSView {
        let wrapper = NSView()
        mount(into: wrapper)
        return wrapper
    }

    func updateNSView(_ wrapper: NSView, context: Context) {
        mount(into: wrapper)
    }

    private func mount(into wrapper: NSView) {
        _ = controller.revision // depend on revision so restarts remount the new view
        guard let term = controller.view(for: sessionID) else { return }
        if term.superview !== wrapper {
            term.removeFromSuperview()
            term.frame = wrapper.bounds
            term.autoresizingMask = [.width, .height]
            wrapper.addSubview(term)
        }
        if isFocused {
            DispatchQueue.main.async { wrapper.window?.makeFirstResponder(term) }
        }
    }
}

/// A single pane in the detail area: optional header chrome + terminal.
struct PaneView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var controller: TerminalController
    let id: UUID
    let showChrome: Bool

    var body: some View {
        let session = appState.session(id: id)
        let focused = appState.selectedSessionID == id
        VStack(spacing: 0) {
            if showChrome {
                HStack(spacing: 6) {
                    Circle()
                        .fill(session?.state.indicatorColor ?? .gray)
                        .frame(width: 7, height: 7)
                    Text(session?.title ?? "—").font(.caption).lineLimit(1)
                    Spacer()
                    Button { appState.closePane(id) } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Close pane")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(focused ? Color.accentColor.opacity(0.18) : Color(nsColor: .windowBackgroundColor))
                .contentShape(Rectangle())
                .onTapGesture { appState.selectedSessionID = id }
                Divider()
            }
            TerminalPaneView(controller: controller, sessionID: id, isFocused: focused)
        }
        .overlay(
            Rectangle()
                .strokeBorder(focused && showChrome ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    let controller: TerminalController

    @State private var newSession: NewSessionDraft?
    @State private var editing: TerminalSession?
    @State private var showProfiles = false
    @State private var editingProfile: Profile?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                onNewSession: { group in newSession = NewSessionDraft(groupID: group?.id) },
                onEditSession: { editing = $0 },
                onSaveGroupAsProfile: { group in editingProfile = appState.makeProfile(from: group) }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button("New Session…") { newSession = NewSessionDraft(groupID: nil) }
                        Button("New Group") { _ = appState.addGroup() }
                        Divider()
                        Menu("Launch Profile") {
                            if appState.profiles.isEmpty {
                                Text("No profiles yet").foregroundStyle(.secondary)
                            } else {
                                ForEach(appState.profiles) { profile in
                                    Button("\(profile.name)  (\(profile.sessionCount))") {
                                        appState.launch(profile)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Save All Groups as Profile…") {
                            editingProfile = appState.makeWorkspaceProfile()
                        }
                        Button("Manage Profiles…") { showProfiles = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if appState.paneIDs.isEmpty {
                        ContentUnavailableView(
                            "No Sessions",
                            systemImage: "terminal",
                            description: Text("Create a session to get started.")
                        )
                    } else {
                        HStack(spacing: 1) {
                            ForEach(appState.paneIDs, id: \.self) { id in
                                PaneView(controller: controller, id: id, showChrome: appState.isSplit)
                            }
                        }
                        .background(Color(nsColor: .separatorColor))
                    }
                }
                if appState.showBroadcastBar {
                    Divider()
                    BroadcastBar(controller: controller)
                }
            }
            .navigationTitle(appState.session(id: appState.selectedSessionID)?.title ?? "TermHub")
            .toolbar {
                ToolbarItemGroup {
                    Button { toggleBroadcastBar() } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .help("Broadcast a command to multiple sessions")
                    .foregroundStyle(appState.showBroadcastBar ? Color.accentColor : Color.primary)

                    Button { appState.splitCurrent() } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .help("Split — show another session beside this one")
                    .disabled(appState.allSessions.count < 2 || appState.paneIDs.count >= AppState.maxPanes)

                    Button { controller.restartSelected() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Restart session")
                    .disabled(appState.selectedSessionID == nil)

                    Button { controller.terminateSelected() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop process")
                    .disabled(appState.selectedSessionID == nil)
                }
            }
        }
        .onAppear {
            controller.attach(appState)
            controller.sync()
        }
        .onChange(of: appState.allSessions.count) { _, _ in
            controller.sync()
        }
        .sheet(item: $newSession) { draft in NewSessionSheet(draft: draft) }
        .sheet(item: $editing) { session in EditSessionSheet(session: session) }
        .sheet(isPresented: $showProfiles) { ManageProfilesSheet() }
        .sheet(item: $editingProfile) { profile in ProfileEditorSheet(profile: profile) }
    }

    private func toggleBroadcastBar() {
        appState.showBroadcastBar.toggle()
        // Sensible default: target the sessions currently on screen.
        if appState.showBroadcastBar && appState.broadcastTargets.isEmpty {
            appState.broadcastTargets = Set(appState.paneIDs)
        }
    }
}

/// Bottom bar to type a command once and send it to all broadcast targets.
struct BroadcastBar: View {
    @EnvironmentObject var appState: AppState
    let controller: TerminalController
    @State private var text = ""
    @FocusState private var focused: Bool

    private var targetCount: Int { appState.orderedBroadcastTargets.count }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.tint)
            Menu {
                Button("All Sessions") {
                    appState.broadcastTargets = Set(appState.allSessions.map(\.id))
                }
                Button("Visible Panes") {
                    appState.broadcastTargets = Set(appState.paneIDs)
                }
                Button("Focused Group") {
                    if let id = appState.selectedSessionID, let g = appState.group(containing: id) {
                        appState.broadcastTargets = Set(g.sessions.map(\.id))
                    }
                }
                Divider()
                Button("Clear Targets") { appState.broadcastTargets = [] }
            } label: {
                Text("\(targetCount) target\(targetCount == 1 ? "" : "s")")
            }
            .fixedSize()

            TextField("Broadcast command to targets…", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(send)

            Button("Send", action: send)
                .disabled(text.isEmpty || targetCount == 0)
        }
        .padding(8)
        .background(.bar)
        .onAppear { focused = true }
    }

    private func send() {
        let cmd = text
        let targets = appState.orderedBroadcastTargets
        guard !cmd.isEmpty, !targets.isEmpty else { return }
        controller.broadcast(cmd, to: targets)
        text = ""
        focused = true
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    var onNewSession: (SessionGroup?) -> Void
    var onEditSession: (TerminalSession) -> Void
    var onSaveGroupAsProfile: (SessionGroup) -> Void

    @State private var renamingGroup: SessionGroup?
    @State private var renameText: String = ""

    var body: some View {
        List(selection: $appState.selectedSessionID) {
            ForEach(appState.groups) { group in
                DisclosureGroup(isExpanded: expansion(for: group)) {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session, isBroadcast: appState.isBroadcastTarget(session.id))
                            .tag(session.id)
                            .draggable(session.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                drop(items, into: group, before: session.id)
                            }
                            .contextMenu {
                                sessionMenu(session, in: group)
                            }
                    }
                } label: {
                    GroupHeader(group: group, count: group.sessions.count)
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, into: group, before: nil)
                        }
                        .contextMenu {
                            groupMenu(group)
                        }
                }
            }
        }
        .alert("Rename Group", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                renamingGroup?.name = renameText
                renamingGroup = nil
            }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        }
    }

    // MARK: Context menus

    @ViewBuilder
    private func sessionMenu(_ session: TerminalSession, in group: SessionGroup) -> some View {
        Button("Edit…") { onEditSession(session) }
        Button("Open in Split") { appState.openInSplit(session.id) }
        Button(appState.isBroadcastTarget(session.id) ? "Remove from Broadcast" : "Add to Broadcast") {
            appState.toggleBroadcast(session.id)
        }
        if appState.groups.count > 1 {
            Menu("Move to Group") {
                ForEach(appState.groups.filter { $0.id != group.id }) { target in
                    Button(target.name) {
                        appState.moveSession(session.id, toGroup: target, before: nil)
                    }
                }
            }
        }
        Divider()
        Button("Remove", role: .destructive) { appState.removeSession(session.id) }
    }

    @ViewBuilder
    private func groupMenu(_ group: SessionGroup) -> some View {
        Button("New Session…") { onNewSession(group) }
        Button("Save as Profile…") { onSaveGroupAsProfile(group) }
        Button("Rename…") {
            renameText = group.name
            renamingGroup = group
        }
        Divider()
        Button("Move Up") { appState.moveGroup(group.id, by: -1) }
        Button("Move Down") { appState.moveGroup(group.id, by: 1) }
        Divider()
        Button("Delete Group", role: .destructive) { appState.removeGroup(group.id) }
    }

    // MARK: Helpers

    private func drop(_ items: [String], into group: SessionGroup, before beforeID: UUID?) -> Bool {
        guard let first = items.first, let dropped = UUID(uuidString: first) else { return false }
        appState.moveSession(dropped, toGroup: group, before: beforeID)
        return true
    }

    private func expansion(for group: SessionGroup) -> Binding<Bool> {
        Binding(get: { group.isExpanded }, set: { group.isExpanded = $0 })
    }
}

struct GroupHeader: View {
    @ObservedObject var group: SessionGroup
    let count: Int

    var body: some View {
        HStack {
            Text(group.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct SessionRow: View {
    @ObservedObject var session: TerminalSession
    var isBroadcast: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.state.indicatorColor)
                .frame(width: 8, height: 8)
            Text(session.title)
                .lineLimit(1)
            Spacer()
            if isBroadcast {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .help("Broadcast target")
            }
            if session.hasUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - New / Edit sheets

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
