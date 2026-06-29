import SwiftUI
import AppKit

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    var controller: TerminalController
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
        Button {
            appState.toggleMute(session.id)
        } label: {
            Label(session.isMuted ? "Unmute" : "Mute",
                  systemImage: session.isMuted ? "speaker.wave.2" : "speaker.slash")
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
        Button("Open Session Log") { openLog(session) }
        Button("Reveal Log in Finder") { revealLog(session) }
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

    private func openLog(_ session: TerminalSession) {
        let url = controller.logURL(for: session.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealLog(_ session: TerminalSession) {
        let url = controller.logURL(for: session.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

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

    /// Pulse only for live output on an unmuted session.
    private var isPulsing: Bool { session.isActive && !session.isMuted }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.state.indicatorColor)
                .frame(width: 8, height: 8)
                .opacity(isPulsing ? 0.35 : 1)
                .scaleEffect(isPulsing ? 1.25 : 1)
                .animation(isPulsing
                    ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                    : .default,
                    value: isPulsing)
                .help(isPulsing ? "Receiving output…" : "")
            Text(session.title)
                .lineLimit(1)
            Spacer()
            if session.isMuted {
                Image(systemName: "speaker.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Muted")
            }
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
