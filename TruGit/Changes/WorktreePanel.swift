import AppKit
import SwiftUI

enum CommitButtonAction: String, CaseIterable {
    case commit, push, commitAndPush

    func title(amending: Bool) -> String {
        switch self {
        case .commit: amending ? "Amend Commit" : "Commit"
        case .push: "Push"
        case .commitAndPush: amending ? "Amend and Push" : "Commit and Push"
        }
    }
}

struct WorktreePanel: View {
    let repository: GitRepository
    let branchColor: Color
    @Binding var draft: CommitDraft
    let upstreamID: String?
    let remotes: [String]
    let canCombine: Bool
    let busy: Bool
    let canPush: Bool
    let pushHelp: String
    let push: () -> Void
    let openChange: (FileChange, DiffRequest.Source?) -> Void
    let perform: (WorktreeAction) -> Void

    @AppStorage(PreferenceKey.commitAction) private var selectedAction: CommitButtonAction = .commitAndPush
    @AppStorage(PreferenceKey.workingTree) private var tree = true
    @AppStorage(PreferenceKey.workingDescending) private var descending = false
    @State private var showingRemoteSetup = false
    @State private var remoteURL = ""
    @State private var chosenRemote: String?
    @State private var discard: [FileChange]?
    @State private var previous: CommitMessage?
    @State private var previousID: String?
    @State private var previousError: String?

    private var available: Bool {
        !busy && repository.integration == nil && !repository.changes.contains { $0.staged == .conflict }
    }

    private var canCommit: Bool {
        guard available, !draft.active.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if draft.amendment != nil { return draft.amendHead == repository.headID }
        return repository.changes.contains { $0.staged != nil }
    }

    private var publishRemote: String? {
        if let chosenRemote, remotes.contains(chosenRemote) { return chosenRemote }
        return remotes.contains("origin") ? "origin" : remotes.first
    }

    private var destination: CommitPushDestination? {
        guard canCombine else { return nil }
        if let upstreamID { return CommitPushDestination(branch: repository.branch, route: .upstream(upstreamID)) }
        guard let publishRemote else { return nil }
        return CommitPushDestination(branch: repository.branch, route: .publish(remote: publishRemote))
    }

    private var combinedHelp: String {
        if let upstreamID { return "Commit staged changes and push to " + upstreamID }
        if let publishRemote { return "Commit staged changes and publish “" + repository.branch + "” to " + publishRemote }
        return "Choose a remote repository to commit and push"
    }

    private var actionEnabled: Bool {
        switch selectedAction {
        case .commit: canCommit
        case .push: canPush
        case .commitAndPush: canCommit && canCombine
        }
    }

    private func commit() {
        guard canCommit else { return }
        perform(.commit(draft, expectedHead: repository.headID))
    }

    private func runSelectedAction() {
        guard actionEnabled else { return }
        switch selectedAction {
        case .commit: commit()
        case .push: push()
        case .commitAndPush:
            if let destination {
                perform(.commit(draft, expectedHead: repository.headID, push: destination))
            } else {
                remoteURL = ""
                showingRemoteSetup = true
            }
        }
    }

    private var remoteSetup: some View {
        let location = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Choose a push destination").font(.headline)
            Text("This repository has no remote. TruGit will save this address as origin and push “" + repository.branch + "” there.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Repository URL or absolute path", text: $remoteURL)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showingRemoteSetup = false }.keyboardShortcut(.cancelAction)
                Button(selectedAction.title(amending: draft.amendment != nil)) {
                    let target = CommitPushDestination(branch: repository.branch, route: .publish(remote: "origin", newURL: location))
                    showingRemoteSetup = false
                    perform(.commit(draft, expectedHead: repository.headID, push: target))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!CommitPushDestination.validRemoteURL(location) || !canCommit || !canCombine)
            }
        }
        .padding(20).frame(width: 420)
    }

    private var commitActionButton: some View {
        let shortcut: (() -> Void)? = canCommit ? { commit() } : nil
        let amending = draft.amendment != nil
        let title = selectedAction.title(amending: amending)
        return HStack(spacing: 0) {
            Button(action: runSelectedAction) {
                Text(title).fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!actionEnabled)
            .opacity(actionEnabled ? 1 : 0.55)
            .help(selectedAction == .commitAndPush ? combinedHelp : selectedAction == .push ? pushHelp : "Save staged changes locally")
            Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 16)
            Menu {
                Picker("Default action", selection: $selectedAction) {
                    ForEach(CommitButtonAction.allCases, id: \.self) { action in
                        Text(action.title(amending: amending)).tag(action)
                    }
                }.pickerStyle(.inline)
            } label: {
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    .frame(width: 30, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Choose commit action")
            .help("Choose the default action")
        }
        .focusedSceneValue(\.commitStagedChanges, shortcut)
        .foregroundStyle(.white)
        .background(Color.teal.opacity(actionEnabled ? 0.85 : 0.45), in: RoundedRectangle(cornerRadius: 5))
    }

    var body: some View {
        let files = repository.changes
        let unstaged = files.filter { $0.workingTree != nil }
        let staged = files.filter { $0.staged != nil && $0.staged != .conflict }
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button { discard = unstaged } label: { Image(systemName: "trash").foregroundStyle(.red) }
                    .accessibilityLabel("Discard unstaged changes").help("Discard unstaged changes")
                    .disabled(!available || unstaged.isEmpty)
                Spacer(minLength: 0)
                Text("\(files.count) file \(files.count == 1 ? "change" : "changes") on").fixedSize()
                Text(repository.branch)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .foregroundStyle(branchColor)
                    .background(branchColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                    .help(repository.branch)
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.medium)).padding(8)
            Divider()
            HStack {
                Button { descending.toggle() } label: {
                    Image(systemName: descending ? "arrow.up" : "arrow.down")
                    Text(descending ? "Z–A" : "A–Z")
                }
                .buttonStyle(.plain).font(.caption).help("Reverse file order")
                Spacer(minLength: 2)
                Picker("File layout", selection: $tree) {
                    Label("Path", systemImage: "list.bullet").tag(false)
                    Label("Tree", systemImage: "list.bullet.indent").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            VSplitView {
                FileSection(staged: false, files: unstaged, tree: tree, descending: descending,
                            available: available, root: repository.root, openChange: openChange,
                            discard: { discard = $0 }, perform: perform)
                FileSection(staged: true, files: staged, tree: tree, descending: descending,
                            available: available, root: repository.root, openChange: openChange,
                            discard: { discard = $0 }, perform: perform)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("Commit", systemImage: "circle.dotted").font(.headline)
                Toggle("Amend previous commit", isOn: Binding(get: { draft.amendment != nil }, set: { enabled in
                    draft.amendment = enabled ? previous : nil
                    draft.amendHead = enabled ? previousID : nil
                }))
                .toggleStyle(.checkbox)
                .disabled(!available || (draft.amendment == nil && (previous == nil || previousID != repository.headID)))
                if let previousError {
                    GitErrorDetails(title: "Couldn’t Load Previous Commit", message: previousError)
                }
                HStack {
                    TextField("Commit summary", text: $draft.active.summary)
                        .textFieldStyle(.plain)
                    Text("\(72 - draft.active.summary.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(draft.active.summary.count > 72 ? Color.orange : .secondary)
                        .help("Characters remaining in the suggested 72-character summary")
                }
                .padding(7).background(WorkspaceColors.history, in: RoundedRectangle(cornerRadius: 4))
                TextField("Description", text: $draft.active.body, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.plain)
                    .padding(7).background(WorkspaceColors.history, in: RoundedRectangle(cornerRadius: 4))
                if selectedAction == .commitAndPush, upstreamID == nil, canCombine, !remotes.isEmpty {
                    Picker("Publish to", selection: Binding(get: { publishRemote }, set: { chosenRemote = $0 })) {
                        ForEach(remotes, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }
                if selectedAction == .commitAndPush, canCombine, upstreamID == nil, remotes.isEmpty {
                    Text("Choose a push destination when you continue.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                commitActionButton
            }
            .disabled(busy)
            .font(.caption).padding(9)
        }
        .sheet(isPresented: $showingRemoteSetup) { remoteSetup }
        .controlSize(.small)
        .background(WorkspaceColors.sidebar)
        .confirmationDialog("Discard unstaged changes?", isPresented: Binding(
            get: { discard != nil }, set: { if !$0 { discard = nil } }), titleVisibility: .visible,
                            presenting: discard) { files in
            Button("Discard \(files.count) unstaged file changes", role: .destructive) { perform(.discardUnstaged(files)) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            if let file = discard?.first, discard?.count == 1 {
                Text(file.workingTree == .untracked ? "Move \(file.path) to the Trash?" : "Restore \(file.path) to its staged contents?")
            } else {
                Text("Restore the selected tracked files to their staged contents and move selected untracked files to the Trash.")
            }
        }
        .task(id: repository.headID) {
            previous = nil
            previousID = nil
            previousError = nil
            guard let head = repository.headID else { return }
            let data: Data
            do {
                data = try await GitRepository.git(["show", "-s", "--format=%s%x00%b", head, "--"], in: repository.root)
            } catch {
                if !Task.isCancelled { previousError = error.localizedDescription }
                return
            }
            guard !Task.isCancelled else { return }
            let fields = data.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return }
            previous = CommitMessage(summary: String(decoding: fields[0], as: UTF8.self),
                                     body: String(decoding: fields[1], as: UTF8.self).trimmingCharacters(in: .newlines))
            previousID = head
        }
    }
}


struct FileHierarchy<Item: Identifiable> {
    struct Row: Identifiable {
        let path: String
        let files: [Item]
        let file: Item?
        enum ID: Hashable { case file(Item.ID), folder(String) }
        var id: ID { file.map { .file($0.id) } ?? .folder(path) }
    }
    let files: [Item]
    let folders: [String: [Item]]
    let path: KeyPath<Item, String>

    // Git paths always use a slash. Preserve the full path as the folder ID so
    // two directories with the same name can be expanded independently.
    init(_ files: [Item], path: KeyPath<Item, String>) {
        self.files = files
        self.path = path
        var result: [String: [Item]] = [:]
        for file in files {
            var directory = ""
            for part in file[keyPath: path].split(separator: "/").dropLast() {
                directory = directory.isEmpty ? String(part) : directory + "/" + part
                result[directory, default: []].append(file)
            }
        }
        self.folders = result
    }

    func rows(tree: Bool, descending: Bool, expanded: Set<String>) -> [Row] {
        let items = files.map { Row(path: $0[keyPath: path], files: [$0], file: $0) } +
                    (tree ? folders : [:]).map { Row(path: $0.key, files: $0.value, file: nil) }
        func visible(_ item: Row) -> Bool {
            guard tree else { return true }
            var parent = item.path[...]
            while let slash = parent.lastIndex(of: "/") {
                parent = parent[..<slash]
                if !expanded.contains(String(parent)) { return false }
            }
            return true
        }
        return items.filter(visible).sorted { left, right in
            if tree {
                let a = left.path.split(separator: "/"), b = right.path.split(separator: "/")
                for i in 0..<min(a.count, b.count) where a[i] != b[i] {
                    let aFolder = i + 1 < a.count || left.file == nil
                    let bFolder = i + 1 < b.count || right.file == nil
                    if aFolder != bFolder { return aFolder }
                    return descending ? a[i] > b[i] : a[i] < b[i]
                }
                if a.count != b.count { return a.count < b.count }
            }
            return descending ? left.path > right.path : left.path < right.path
        }
    }

}

private struct FileSection: View {
    let staged: Bool
    let files: [FileChange]
    let tree: Bool
    let descending: Bool
    let available: Bool
    let root: URL
    let openChange: (FileChange, DiffRequest.Source?) -> Void
    let discard: ([FileChange]) -> Void
    let perform: (WorktreeAction) -> Void
    @State private var collapsed = false
    @State private var expanded: Set<String> = []

    private func status(_ file: FileChange) -> FileChange.Status {
        (staged ? file.staged : file.workingTree) ?? .changed
    }

    private var verb: String { staged ? "Unstage" : "Stage" }

    private func changeIndex(_ files: [FileChange]?) {
        let paths = files.map { files in
            Array(Set(files.flatMap { file -> [String] in
                if status(file) == .renamed, let original = file.originalPath { return [original, file.path] }
                return [file.path]
            }))
        }
        perform(staged ? .unstage(paths) : .stage(paths))
    }

    var body: some View {
        let hierarchy = FileHierarchy(files, path: \.path)
        let groups = hierarchy.folders
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { collapsed.toggle() } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    Text("\(staged ? "Staged" : "Unstaged") Files (\(files.count))")
                        .lineLimit(1)
                }.buttonStyle(.plain)
                Spacer(minLength: 0)
                if !files.isEmpty {
                    if staged {
                        Button("Unstage All") { changeIndex(nil) }.disabled(!available)
                    } else {
                        Button("Stage All Changes") { changeIndex(nil) }
                            .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!available)
                    }
                }
            }
            .font(.caption.weight(.semibold)).padding(.horizontal, 8).frame(minHeight: 28)
            .background(WorkspaceColors.panel)
            .contextMenu {
                Button(staged ? "Unstage All" : "Stage All Changes") { changeIndex(nil) }
                    .disabled(!available || files.isEmpty)
                Button(collapsed ? "Expand Section" : "Collapse Section") { collapsed.toggle() }
            }
            if !collapsed {
                WorkspaceScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if tree && !groups.isEmpty {
                            let allExpanded = Set(groups.keys).isSubset(of: expanded)
                            Button(allExpanded ? "Collapse All" : "Expand All") {
                                expanded = allExpanded ? [] : Set(groups.keys)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.vertical, 3)
                        }
                        ForEach(hierarchy.rows(tree: tree, descending: descending, expanded: expanded)) { row in
                            fileRow(row)
                                .padding(.leading, tree ? CGFloat(row.path.split(separator: "/").count - 1) * 10 : 0)
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: collapsed ? 28 : 46,
               maxHeight: collapsed ? 28 : .infinity, alignment: .top)
    }

    private func fileRow(_ row: FileHierarchy<FileChange>.Row) -> some View {
        HStack(spacing: 5) {
            Button {
                if let file = row.file {
                    openChange(file, staged ? .staged : .workingTree(status(file)))
                } else if expanded.contains(row.path) { expanded.remove(row.path) }
                else { expanded.insert(row.path) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: row.file != nil ? "doc" : expanded.contains(row.path) ? "chevron.down" : "chevron.right")
                    Text(tree ? String(row.path.split(separator: "/").last ?? "") : row.path)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    if let file = row.file {
                        Text(status(file).rawValue).foregroundStyle(statusColor(status(file)))
                    } else {
                        let counts = Dictionary(grouping: row.files, by: status)
                        ForEach(counts.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { state in
                            HStack(spacing: 2) {
                                Image(systemName: state.icon)
                                Text("\(counts[state]?.count ?? 0)")
                            }.foregroundStyle(statusColor(state)).help(state.rawValue)
                        }
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(row.path)
            Button { changeIndex(row.files) } label: {
                Image(systemName: staged ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(.plain).foregroundStyle(staged ? Color.orange : .mint)
            .accessibilityLabel("\(verb) \(row.path)").help("\(verb) \(row.path)").disabled(!available)
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .contextMenu {
            if let file = row.file {
                Button("Open Diff") { openChange(file, staged ? .staged : .workingTree(status(file))) }
            } else {
                Button(expanded.contains(row.path) ? "Collapse Folder" : "Expand Folder") {
                    if expanded.contains(row.path) { expanded.remove(row.path) } else { expanded.insert(row.path) }
                }
            }
            Button("\(verb) \(row.file == nil ? "Folder" : "File")") { changeIndex(row.files) }
                .disabled(!available)
            if !staged {
                Button("Discard Unstaged Changes…", role: .destructive) { discard(row.files) }
                    .disabled(!available)
            }
            Divider()
            FileLocationMenu(root: root, path: row.path)
        }
    }
}

extension FileChange.Status {
    var icon: String {
        switch self {
        case .added, .copied, .untracked: "plus"
        case .deleted: "minus"
        case .renamed: "arrow.right"
        case .conflict: "exclamationmark.triangle"
        default: "pencil"
        }
    }
}

func copyGitText(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

struct FileLocationMenu: View {
    let root: URL
    let path: String

    var body: some View {
        let url = root.appendingPathComponent(path)
        Button("Copy Relative Path") { copyGitText(path) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .disabled(!FileManager.default.fileExists(atPath: url.path))
    }
}
