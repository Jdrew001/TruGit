import SwiftUI

struct CommitJump: Equatable {
    let id = UUID()
    let commitID: String
}

enum RepositorySelection: Hashable {
    case history
    case pullRequests
    case reference(String)
}

struct SwitchStep {
    let from: String
    let head: String
    let to: String
    var action: GitBranchAction { .replaySwitch(from: from, expectedHead: head, to: to) }
}

@MainActor
@Observable
final class RepositoryTab: Identifiable {
    nonisolated let id: URL
    var snapshot: RepositorySnapshot {
        didSet {
            if oldValue.repository.integration != snapshot.repository.integration,
               snapshot.repository.integration != nil {
                showWorkInProgress()
            }
        }
    }
    var selection: RepositorySelection? = .history
    var pushingTo: String?
    var switchUndo: SwitchStep?
    var switchRedo: SwitchStep?
    var referenceFilter = ""
    private let sidebarPreferencesKey: String
    var sidebarSections: [String: Bool] {
        didSet { UserDefaults.standard.set(sidebarSections, forKey: sidebarPreferencesKey) }
    }
    var historySelection: HistorySelection?
    var worktreeFileCommit: String?
    var commitJump: CommitJump?
    var commitDraft = CommitDraft()
    var pendingCommitBatch: CommitBatch?
    var diff: DiffSelection?

    var alias: String?
    var folderName: String { id.lastPathComponent.isEmpty ? id.path : id.lastPathComponent }
    var title: String { alias ?? folderName }

    init(snapshot: RepositorySnapshot, alias: String? = nil) {
        self.alias = alias
        self.id = snapshot.repository.root
        self.snapshot = snapshot
        let key = "sidebarSections.v1." + snapshot.repository.root.standardizedFileURL.path
        sidebarPreferencesKey = key
        sidebarSections = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        if snapshot.repository.integration != nil { showWorkInProgress() }
    }

    func showWorkInProgress() {
        selection = .history
        historySelection = .workInProgress
        commitJump = nil
    }

    func selectReference(_ reference: RepositoryReference) {
        selection = .reference(reference.id)
        diff = nil
        historySelection = .commit(reference.commitID)
        commitJump = CommitJump(commitID: reference.commitID)
    }
}

private enum GroupEditor: Identifiable {
    case create(RepositoryTab)
    case rename(RepositoryTabGroup)

    var id: String {
        switch self {
        case .create(let tab): tab.id.path
        case .rename(let group): group.id.uuidString
        }
    }

    var initialName: String {
        if case .rename(let group) = self { return group.name }
        return ""
    }

    func change(_ name: String) -> TabOrganizationChange {
        switch self {
        case .create(let tab): .create(tab.id.path, name: name)
        case .rename(let group): .rename(group.id, name)
        }
    }
}

private extension TabGroupColor {
    var tint: Color {
        switch self {
        case .cyan: .cyan
        case .purple: .purple
        case .mint: .mint
        case .pink: .pink
        case .blue: .blue
        case .orange: .orange
        }
    }

    var name: String { String(describing: self).capitalized }
}

struct RepositoryTabs: View {
    let model: RepositoryModel
    let sidebarExpanded: Bool
    let toggleSidebar: () -> Void
    @State private var editingAlias: RepositoryTab?
    @State private var groupEditor: GroupEditor?

    var body: some View {
        let groups = model.tabGroups
        let memberships = Dictionary(uniqueKeysWithValues: groups.flatMap { group in group.members.map { ($0, group) } })
        let firstMembers = Dictionary(grouping: model.tabs, by: { memberships[$0.id.path]?.id })
            .compactMapValues { $0.first?.id }
        HStack(spacing: 0) {
            sidebarButton
            AppZoomControls()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(model.tabs) { tab in
                            let group = memberships[tab.id.path]
                            if let group, firstMembers[group.id] == tab.id {
                                groupHeader(group).id(group.id)
                            }
                            if group?.collapsed != true {
                                repositoryTab(tab, group: group).id(tab.id)
                            }
                        }
                        addRepositoryButton.id("addRepository")
                    }.padding(.leading, 2)
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.activeID, initial: true) {
                    guard let selected = model.activeID else { return }
                    if let group = memberships[selected.path], group.collapsed { proxy.scrollTo(group.id) }
                    else if selected == model.tabs.last?.id { proxy.scrollTo("addRepository", anchor: .trailing) }
                    else { proxy.scrollTo(selected) }
                }
            }
            SettingsLink {
                Image(systemName: "gearshape").frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Settings").help("Settings (⌘,)")
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
        .background(WorkspaceColors.sidebar)
        .overlay(alignment: .bottom) { WorkspaceColors.divider.frame(height: 1) }
        .sheet(item: $editingAlias) { tab in
            TabAliasEditor(tab: tab) { name in model.setAlias(name, for: tab) }
                .zoomAppDialog()
        }
        .sheet(item: $groupEditor) { editor in
            GroupNameEditor(editor: editor) { model.organizeTabs(editor.change($0)) }
                .zoomAppDialog()
        }
    }

    private func groupHeader(_ group: RepositoryTabGroup) -> some View {
        let active = group.collapsed && model.activeID.map { group.members.contains($0.path) } == true
        return Button { model.organizeTabs(.toggle(group.id)) } label: {
            HStack(spacing: 5) {
                Image(systemName: group.collapsed ? "chevron.right" : "chevron.down").font(.caption2)
                Text(group.name).lineLimit(1).truncationMode(.tail)
                if group.collapsed { Text(group.members.count, format: .number).monospacedDigit() }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(group.color.tint)
            .padding(.horizontal, 7).frame(height: 22)
            .background(group.color.tint.opacity(active ? 0.27 : 0.13), in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 4).frame(maxWidth: 185, minHeight: 34)
            .fixedSize(horizontal: true, vertical: false).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.name)
        .accessibilityValue(group.collapsed ? "Collapsed" : "Expanded")
        .help((group.collapsed ? "Expand " : "Collapse ") + group.name + " · Drag to move group")
        .contextMenu {
            Picker("Group Color", selection: Binding(
                get: { group.color },
                set: { model.organizeTabs(.setColor(group.id, $0)) }
            )) {
                ForEach(TabGroupColor.allCases, id: \.self) { color in
                    Label {
                        Text(color.name)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(color.tint)
                    }
                    .tag(color)
                }
            }
            .pickerStyle(.palette)
            Divider()
            Button("Rename Group…") { groupEditor = .rename(group) }
            Button("Ungroup Tabs") { model.organizeTabs(.ungroup(group.id)) }
        }
        .overlay { RepositoryTabDrag(target: .group(group.id), model: model).accessibilityHidden(true) }
    }

    private var addRepositoryButton: some View {
        HStack(spacing: 0) {
            Button(action: model.openRepository) {
                Image(systemName: "plus")
                    .frame(width: 28, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add repository")
            .help("Open or initialize one or more repositories (⌘O)")

            Menu {
                Button("Add Local Repositories…", action: model.openRepository)
                Button("Clone Repository…", action: model.showCloneSheet)
            } label: {
                Image(systemName: "chevron.down").font(.caption2)
                    .frame(width: 18, height: 34).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Repository options").help("Repository options")
        }
        .disabled(model.isLoading)
        .overlay { RepositoryTabDrag(target: .end, model: model).accessibilityHidden(true) }
    }

    private var sidebarButton: some View {
        let title = sidebarExpanded ? "Hide Sidebar" : "Show Sidebar"
        return Button(action: toggleSidebar) {
            Image(systemName: sidebarExpanded ? "sidebar.leading" : "rectangle.leadinghalf.inset.filled.arrow.leading")
                .frame(width: 36, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).help(title)
    }

    private func repositoryTab(_ tab: RepositoryTab, group: RepositoryTabGroup?) -> some View {
        let isSelected = tab.id == model.activeID
        return HStack(spacing: 5) {
            Button { model.selectTab(tab.id) } label: {
                Label(tab.title, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 8)
                    .frame(maxWidth: 148, minHeight: 34, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(tab.id.path)

            Button { model.closeTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 25).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)").help("Close tab")
        }
        .fixedSize(horizontal: true, vertical: false)
        .font(.callout.weight(isSelected ? .semibold : .medium))
        .background(isSelected ? WorkspaceColors.panel : WorkspaceColors.sidebar)
        .overlay(alignment: .trailing) { WorkspaceColors.divider.frame(width: 1) }
        .overlay(alignment: .bottom) { if let group { group.color.tint.frame(height: 2) } }
        .contextMenu {
            Menu("Move Tab to Group") {
                Button("New Group…") { groupEditor = .create(tab) }
                ForEach(model.tabGroups.filter { $0.id != group?.id }) { target in
                    Button(target.name) { model.organizeTabs(.move(tab.id.path, .group(target.id))) }
                }
            }
            if group != nil {
                Button("Remove from Group") { model.organizeTabs(.removeFromGroup(tab.id.path)) }
            }
            Divider()
            Button("Edit Tab Alias…", systemImage: "pencil") { editingAlias = tab }
            if tab.alias != nil { Button("Remove Alias") { model.setAlias("", for: tab) } }
        }
        .accessibilityAction(named: "Edit Tab Alias") { editingAlias = tab }
        .overlay { RepositoryTabDrag(target: .tab(tab), model: model).accessibilityHidden(true) }
    }
}

private struct GroupNameEditor: View {
    let editor: GroupEditor
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(editor: GroupEditor, save: @escaping (String) -> Void) {
        self.editor = editor
        self.save = save
        _name = State(initialValue: editor.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.initialName.isEmpty ? "New Tab Group" : "Rename Tab Group").font(.headline)
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(name); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 320)
        .onAppear { focused = true }
    }
}

private struct TabAliasEditor: View {
    let tab: RepositoryTab
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(tab: RepositoryTab, save: @escaping (String) -> Void) {
        self.tab = tab
        self.save = save
        _name = State(initialValue: tab.alias ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Tab Alias").font(.headline)
            Text(tab.id.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextField(tab.folderName, text: $name).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Tab alias").focused($focused)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(name); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 360)
        .onAppear { focused = true }
    }
}
