import SwiftUI

/// Lists saved profiles with actions to launch, edit, delete, or create.
struct ManageProfilesSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Button {
                    editing = Profile(groups: [GroupTemplate(templates: [SessionTemplate()])])
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
            }
            .padding()
            Divider()

            if appState.profiles.isEmpty {
                ContentUnavailableView(
                    "No Profiles",
                    systemImage: "rectangle.stack",
                    description: Text("Create a profile, or use “Save All Groups as Profile”, to launch a set of sessions at once.")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List {
                    ForEach(appState.profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).fontWeight(.medium)
                                Text(summary(profile))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Launch") {
                                appState.launch(profile)
                                dismiss()
                            }
                            Button {
                                editing = profile
                            } label: { Image(systemName: "pencil") }
                            Button(role: .destructive) {
                                appState.removeProfile(profile.id)
                            } label: { Image(systemName: "trash") }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 440)
        .sheet(item: $editing) { profile in
            ProfileEditorSheet(profile: profile)
        }
    }

    private func summary(_ profile: Profile) -> String {
        let sessions = profile.sessionCount
        let s = "\(sessions) session\(sessions == 1 ? "" : "s")"
        if profile.groups.count > 1 {
            return "\(profile.groups.count) groups · \(s)"
        }
        return s
    }
}

/// Edit a profile: its name, groups, and the sessions inside each group.
struct ProfileEditorSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State var profile: Profile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Profile").font(.headline).padding()
            Divider()

            Form {
                TextField("Profile name", text: $profile.name)

                ForEach($profile.groups) { $group in
                    Section {
                        TextField("Group name", text: $group.name)

                        ForEach($group.templates) { $tpl in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    TextField("Title", text: $tpl.title)
                                    Button(role: .destructive) {
                                        group.templates.removeAll { $0.id == tpl.id }
                                    } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                }
                                TextField("Command (optional)", text: $tpl.command)
                                HStack {
                                    TextField("Working dir (optional)", text: $tpl.workingDirectory)
                                    Button("Choose…") { chooseDirectory(for: tpl.id) }
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        Button {
                            group.templates.append(SessionTemplate())
                        } label: {
                            Label("Add Session", systemImage: "plus")
                        }
                    } header: {
                        HStack {
                            Text(group.name.isEmpty ? "Group" : group.name)
                            Spacer()
                            Button(role: .destructive) {
                                profile.groups.removeAll { $0.id == group.id }
                            } label: {
                                Label("Remove Group", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                            .labelStyle(.iconOnly)
                        }
                    }
                }

                Button {
                    profile.groups.append(GroupTemplate(templates: [SessionTemplate()]))
                } label: {
                    Label("Add Group", systemImage: "plus.rectangle.on.rectangle")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    appState.upsertProfile(profile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.sessionCount == 0)
            }
            .padding()
        }
        .frame(width: 540, height: 560)
    }

    private func chooseDirectory(for templateID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        for gi in profile.groups.indices {
            if let ti = profile.groups[gi].templates.firstIndex(where: { $0.id == templateID }) {
                profile.groups[gi].templates[ti].workingDirectory = url.path
                return
            }
        }
    }
}
