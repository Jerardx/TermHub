import SwiftUI
import AppKit

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
                controller: controller,
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
