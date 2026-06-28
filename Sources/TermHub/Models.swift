import Foundation
import Combine

/// Run state of a single terminal session, used for the status indicator in the sidebar.
enum SessionState: Equatable {
    case notStarted
    case running
    case exited(Int32)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// One terminal session: a shell (optionally auto-running a command) in a working directory.
final class TerminalSession: ObservableObject, Identifiable, Codable {
    let id: UUID
    @Published var title: String
    /// Optional command auto-typed into the shell on start (empty = just an interactive shell).
    @Published var command: String
    /// Working directory the shell starts in (empty = home directory).
    @Published var workingDirectory: String

    // Runtime-only state (not persisted).
    @Published var state: SessionState = .notStarted
    @Published var hasUnread: Bool = false

    init(title: String, command: String = "", workingDirectory: String = "") {
        self.id = UUID()
        self.title = title
        self.command = command
        self.workingDirectory = workingDirectory
    }

    // MARK: Codable (persist configuration only, not live state)
    private enum CodingKeys: String, CodingKey {
        case id, title, command, workingDirectory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(command, forKey: .command)
        try c.encode(workingDirectory, forKey: .workingDirectory)
    }
}

/// A named, collapsible group of sessions shown in the sidebar.
final class SessionGroup: ObservableObject, Identifiable, Codable {
    let id: UUID
    @Published var name: String
    @Published var sessions: [TerminalSession]
    @Published var isExpanded: Bool

    init(name: String, sessions: [TerminalSession] = [], isExpanded: Bool = true) {
        self.id = UUID()
        self.name = name
        self.sessions = sessions
        self.isExpanded = isExpanded
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sessions, isExpanded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sessions = try c.decode([TerminalSession].self, forKey: .sessions)
        isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(sessions, forKey: .sessions)
        try c.encode(isExpanded, forKey: .isExpanded)
    }
}

/// One session definition inside a profile (value type for easy form editing).
struct SessionTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = "shell"
    var command: String = ""
    var workingDirectory: String = ""
}

/// A group of session templates inside a profile.
struct GroupTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = "Group"
    var templates: [SessionTemplate] = []
}

/// A reusable set of groups + sessions that can be launched together with one
/// click. Can capture a single group or the whole workspace (all groups).
struct Profile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = "New Profile"
    var groups: [GroupTemplate] = []

    var sessionCount: Int { groups.reduce(0) { $0 + $1.templates.count } }

    init(id: UUID = UUID(), name: String = "New Profile", groups: [GroupTemplate] = []) {
        self.id = id
        self.name = name
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey { case id, name, groups, templates }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        if let groups = try c.decodeIfPresent([GroupTemplate].self, forKey: .groups) {
            self.groups = groups
        } else if let flat = try c.decodeIfPresent([SessionTemplate].self, forKey: .templates) {
            // Migrate old single-group profiles.
            self.groups = [GroupTemplate(name: name, templates: flat)]
        } else {
            self.groups = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(groups, forKey: .groups)
    }
}

/// Top-level application state: the list of groups and the current selection.
@MainActor
final class AppState: ObservableObject {
    @Published var groups: [SessionGroup] = []
    @Published var profiles: [Profile] = []

    /// Sessions currently shown in the detail area, left-to-right (split view).
    /// Always contains the focused session; count 1 == single view.
    @Published var paneIDs: [UUID] = []

    @Published var selectedSessionID: UUID? {
        didSet {
            clearUnread(selectedSessionID)
            reconcilePanes(previous: oldValue)
        }
    }

    static let maxPanes = 4

    /// Broadcast input feature: sessions that receive broadcast commands.
    @Published var broadcastTargets: Set<UUID> = []
    @Published var showBroadcastBar: Bool = false

    func isBroadcastTarget(_ id: UUID) -> Bool { broadcastTargets.contains(id) }

    func toggleBroadcast(_ id: UUID) {
        if broadcastTargets.contains(id) { broadcastTargets.remove(id) }
        else { broadcastTargets.insert(id) }
    }

    /// Targets that still exist, in workspace order.
    var orderedBroadcastTargets: [UUID] {
        allSessions.map(\.id).filter { broadcastTargets.contains($0) }
    }

    private var cancellables: Set<AnyCancellable> = []

    init() {
        load()
        loadProfiles()
        if groups.isEmpty {
            seedDefault()
        }
        rewireAutosave()
    }

    // MARK: Lookup

    func session(id: UUID?) -> TerminalSession? {
        guard let id else { return nil }
        for g in groups {
            if let s = g.sessions.first(where: { $0.id == id }) { return s }
        }
        return nil
    }

    func group(containing sessionID: UUID) -> SessionGroup? {
        groups.first { $0.sessions.contains { $0.id == sessionID } }
    }

    var allSessions: [TerminalSession] { groups.flatMap(\.sessions) }

    // MARK: Mutations

    func addGroup(name: String = "New Group") -> SessionGroup {
        let g = SessionGroup(name: name)
        groups.append(g)
        rewireAutosave()
        save()
        return g
    }

    func addSession(to group: SessionGroup, session: TerminalSession, select: Bool = true) {
        group.sessions.append(session)
        if select { selectedSessionID = session.id }
        rewireAutosave()
        save()
    }

    func removeSession(_ id: UUID) {
        for g in groups {
            if let idx = g.sessions.firstIndex(where: { $0.id == id }) {
                g.sessions.remove(at: idx)
                break
            }
        }
        paneIDs.removeAll { $0 == id }
        broadcastTargets.remove(id)
        if selectedSessionID == id {
            selectedSessionID = allSessions.first?.id
        } else if paneIDs.isEmpty, let sel = selectedSessionID {
            paneIDs = [sel]
        }
        save()
    }

    func removeGroup(_ id: UUID) {
        let removedIDs = Set(groups.first(where: { $0.id == id })?.sessions.map(\.id) ?? [])
        groups.removeAll { $0.id == id }
        paneIDs.removeAll { removedIDs.contains($0) }
        broadcastTargets.subtract(removedIDs)
        if let sel = selectedSessionID, removedIDs.contains(sel) {
            selectedSessionID = allSessions.first?.id
        } else if paneIDs.isEmpty, let sel = selectedSessionID {
            paneIDs = [sel]
        }
        save()
    }

    func clearUnread(_ id: UUID?) {
        session(id: id)?.hasUnread = false
    }

    // MARK: Navigation

    func select(index: Int) {
        let all = allSessions
        guard all.indices.contains(index) else { return }
        selectedSessionID = all[index].id
    }

    func selectNext() {
        let all = allSessions
        guard !all.isEmpty else { return }
        if let cur = selectedSessionID, let i = all.firstIndex(where: { $0.id == cur }) {
            selectedSessionID = all[(i + 1) % all.count].id
        } else {
            selectedSessionID = all.first?.id
        }
    }

    func selectPrevious() {
        let all = allSessions
        guard !all.isEmpty else { return }
        if let cur = selectedSessionID, let i = all.firstIndex(where: { $0.id == cur }) {
            selectedSessionID = all[(i - 1 + all.count) % all.count].id
        } else {
            selectedSessionID = all.last?.id
        }
    }

    // MARK: Split panes

    var isSplit: Bool { paneIDs.count > 1 }

    /// Keep `paneIDs` consistent when the focused session changes.
    private func reconcilePanes(previous: UUID?) {
        guard let id = selectedSessionID else { paneIDs = []; return }
        if paneIDs.count <= 1 {
            paneIDs = [id]
        } else if !paneIDs.contains(id) {
            // Load the newly focused session into the previously focused pane.
            if let prev = previous, let i = paneIDs.firstIndex(of: prev) {
                paneIDs[i] = id
            } else {
                paneIDs = [id]
            }
        }
        // If `id` is already a pane, just leave the layout and treat it as focused.
    }

    /// Add another pane showing the first session not already on screen.
    func splitCurrent() {
        guard paneIDs.count < Self.maxPanes else { return }
        guard let candidate = allSessions.map(\.id).first(where: { !paneIDs.contains($0) }) else { return }
        paneIDs.append(candidate)
        selectedSessionID = candidate
    }

    func closePane(_ id: UUID) {
        guard paneIDs.count > 1 else { return }
        paneIDs.removeAll { $0 == id }
        if selectedSessionID == id {
            selectedSessionID = paneIDs.first
        }
    }

    /// Open a specific session as an additional pane beside the current ones.
    func openInSplit(_ id: UUID) {
        if paneIDs.contains(id) || paneIDs.count >= Self.maxPanes {
            selectedSessionID = id
            return
        }
        paneIDs.append(id)
        selectedSessionID = id
    }

    // MARK: Drag & drop / reordering

    func moveGroup(_ id: UUID, by delta: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard groups.indices.contains(j) else { return }
        groups.swapAt(i, j)
        save()
    }

    /// Move a session into `target`, inserting before `beforeID` (or at the end).
    /// Works both within a group (reorder) and across groups.
    func moveSession(_ id: UUID, toGroup target: SessionGroup, before beforeID: UUID?) {
        guard id != beforeID,
              let source = group(containing: id),
              let session = source.sessions.first(where: { $0.id == id }) else { return }
        source.sessions.removeAll { $0.id == id }
        if let beforeID, let idx = target.sessions.firstIndex(where: { $0.id == beforeID }) {
            target.sessions.insert(session, at: idx)
        } else {
            target.sessions.append(session)
        }
        rewireAutosave()
        save()
    }

    // MARK: Profiles

    func upsertProfile(_ profile: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        saveProfiles()
    }

    func removeProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        saveProfiles()
    }

    private func groupTemplate(from group: SessionGroup) -> GroupTemplate {
        GroupTemplate(
            name: group.name,
            templates: group.sessions.map {
                SessionTemplate(title: $0.title, command: $0.command, workingDirectory: $0.workingDirectory)
            }
        )
    }

    /// Build a profile capturing a single group's configuration.
    func makeProfile(from group: SessionGroup) -> Profile {
        Profile(name: group.name, groups: [groupTemplate(from: group)])
    }

    /// Build a profile capturing the entire workspace (all groups).
    func makeWorkspaceProfile() -> Profile {
        Profile(name: "Workspace", groups: groups.map(groupTemplate(from:)))
    }

    /// Launch a profile: recreate all of its groups + sessions and start them.
    func launch(_ profile: Profile) {
        var firstSessionID: UUID?
        for groupTemplate in profile.groups {
            let group = SessionGroup(name: groupTemplate.name)
            group.sessions = groupTemplate.templates.map {
                TerminalSession(title: $0.title, command: $0.command, workingDirectory: $0.workingDirectory)
            }
            groups.append(group)
            if firstSessionID == nil { firstSessionID = group.sessions.first?.id }
        }
        if let firstSessionID { selectedSessionID = firstSessionID }
        rewireAutosave()
        save()
    }

    // MARK: Persistence

    private func supportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("TermHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func storeURL() -> URL {
        supportDir().appendingPathComponent("config.json")
    }

    private func profilesURL() -> URL {
        supportDir().appendingPathComponent("profiles.json")
    }

    func saveProfiles() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: profilesURL(), options: .atomic)
        } catch {
            NSLog("TermHub: save profiles failed: \(error)")
        }
    }

    private func loadProfiles() {
        guard let data = try? Data(contentsOf: profilesURL()),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data) else { return }
        profiles = decoded
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(groups)
            try data.write(to: storeURL(), options: .atomic)
        } catch {
            NSLog("TermHub: save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL()) else { return }
        if let decoded = try? JSONDecoder().decode([SessionGroup].self, from: data) {
            groups = decoded
            selectedSessionID = decoded.flatMap(\.sessions).first?.id
        }
    }

    private func seedDefault() {
        let g = SessionGroup(name: "General")
        let s = TerminalSession(title: "shell")
        g.sessions = [s]
        groups = [g]
        selectedSessionID = s.id
        save()
    }

    /// Re-subscribe to nested @Published changes so renames/edits trigger autosave.
    private func rewireAutosave() {
        cancellables.removeAll()
        for g in groups {
            g.objectWillChange
                .sink { [weak self] in DispatchQueue.main.async { self?.save() } }
                .store(in: &cancellables)
            for s in g.sessions {
                s.objectWillChange
                    .sink { [weak self] in DispatchQueue.main.async { self?.save() } }
                    .store(in: &cancellables)
            }
        }
    }
}
