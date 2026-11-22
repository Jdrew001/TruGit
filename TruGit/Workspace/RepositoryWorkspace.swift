import AppKit
import SwiftUI

enum WorkspaceColors {
    static let history = Color(red: 0.034, green: 0.042, blue: 0.046)
    static let sidebar = Color(red: 0.078, green: 0.088, blue: 0.094)
    static let panel = Color(red: 0.122, green: 0.137, blue: 0.146)
    static let divider = Color(red: 0.17, green: 0.185, blue: 0.196)
    static let accent = Color(red: 0.38, green: 0.71, blue: 1)
    static let selection = Color(red: 0.135, green: 0.275, blue: 0.415)
}

struct RepositoryWorkspace: View {
    @Bindable var tab: RepositoryTab
    let sidebarExpanded: Bool
    let canChangeBranch: Bool
    let openWorktree: (URL) -> Void
    let selectTab: (URL) -> Void
    let refresh: () -> Void
    let repoTabs: [RepositoryTab]
    let openRepository: () -> Void
    let performBranchAction: (GitBranchAction) -> Void
    @AppStorage("repositorySidebarWidth") private var sidebarWidth: Double = 224
    @State private var draggingSidebar: CGFloat?
    @State private var searching = false
    @State private var pushBranch: RepositoryReference?
    @State private var publishBranch: RepositoryReference?
    @State private var collapsedSearchGroups: Set<RepositoryReference.Kind> = []
    @State private var tagTarget: RevisionPoint?
    @State private var branchDraft: BranchDraft?
    @State private var newBranchName = ""
    @State private var revisionReview: RevisionReview?
    @State private var mergeReview: BranchMergeReview?
    @State private var commitBatch: CommitBatch?
    @State private var deleting: BranchDeletion?
    @State private var stashToDelete: GitStash?

    private var snapshot: RepositorySnapshot { tab.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            if tab.selection == .pullRequests {
                PullRequestsView(root: tab.id, remotes: snapshot.remotes, branch: snapshot.repository.branch, showsInbox: sidebarExpanded) {
                    tab.selection = .history
                }
            } else {
                commandBar
                if let destination = tab.pushingTo {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Pushing to " + destination + "…")
                        Spacer()
                    }
                    .font(.callout).padding(.horizontal, 12).padding(.vertical, 5)
                    .background(WorkspaceColors.panel)
                }
                if let integration = snapshot.repository.integration {
                    IntegrationBar(integration: integration, operation: snapshot.operationTitle, hasConflicts: hasConflicts,
                                   isBusy: !canChangeBranch, perform: performBranchAction)
                }
                GeometryReader { geo in
                    let limits = CGFloat(150)...max(150, geo.size.width - 490)
                    let width = min(limits.upperBound, max(limits.lowerBound, draggingSidebar ?? sidebarWidth))
                    HStack(spacing: 0) {
                        if sidebarExpanded {
                            sidebar.frame(width: width)
                            WidthDivider(label: "Sidebar width", width: width, limits: limits) { value, finished in
                                if finished { sidebarWidth = value; draggingSidebar = nil }
                                else { draggingSidebar = value }
                            }.frame(width: 8)
                        }
                        detail.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .tint(WorkspaceColors.accent)
        .navigationTitle(tab.title)
        .navigationSubtitle(snapshot.repository.branch)
        .onChange(of: snapshot.references, initial: true) {
            if case .reference = tab.selection, selectedReference == nil {
                tab.selection = .history
            }
        }
        .onChange(of: tab.referenceFilter) { collapsedSearchGroups.removeAll() }
        .onChange(of: tab.historySelection) { tab.diff = nil }
        .onChange(of: tab.selection) {
            tab.diff = nil
            if let reference = selectedReference {
                tab.commitJump = CommitJump(commitID: reference.commitID)
            }
        }
        .alert(branchDraft?.title ?? "Create Branch", isPresented: namingBranch, presenting: branchDraft) { draft in
            TextField("Branch name", text: $newBranchName)
            Button("Create and Switch") {
                performBranchAction(draft.action(named: trimmedBranchName))
            }
            .disabled(trimmedBranchName.isEmpty || branchNameTaken || !canMoveBranches)
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            Text(branchNameTaken ? draft.message + " A local branch already uses that name. Enter a different name." : draft.message)
        }
        .alert("Delete Stash?", isPresented: Binding(get: { stashToDelete != nil }, set: { if !$0 { stashToDelete = nil } }),
               presenting: stashToDelete) { stash in
            Button("Delete Stash", role: .destructive) { performBranchAction(.stashEntry(.delete, stash)) }
            Button("Cancel", role: .cancel) {}
        } message: { stash in
            Text("Remove \(stash.selector) “\(stash.subject)” from this repository’s stash list?")
        }
        .sheet(item: $publishBranch) { branch in
            PublishBranchSheet(branch: branch, remotes: snapshot.remotes) { remote, url in
                performBranchAction(.publish(branch, remote: remote, newURL: url))
            }
            .zoomAppDialog()
        }
        .sheet(item: $tagTarget) { point in
            CreateTagSheet(point: point, tags: Set(snapshot.references.filter { $0.kind == .tag }.map(\.name)),
                           remotes: snapshot.remotes) { performBranchAction(.revision($0)) }
                .zoomAppDialog()
        }
        .sheet(item: $deleting) { choice in
            BranchDeletePrompt(choice: choice) { deletion, force in
                performBranchAction(.deleteBranch(deletion, forceLocal: force))
            }
            .zoomAppDialog()
        }
        .sheet(item: $commitBatch) { batch in
            CommitBatchSheet(batch: batch, otherWorktree: snapshot.otherWorktree, addFromGraph: pickMoreCommits) { performBranchAction(.revision($0)) }
                .zoomAppDialog()
        }
        .sheet(item: $mergeReview) { review in
            MergeBranchesSheet(review: review, root: tab.id, current: snapshot.repository.branch, otherWorktree: snapshot.otherWorktree,
                               canMerge: canMoveBranches) { performBranchAction(.revision($0)) }
                .zoomAppDialog()
        }
        .sheet(item: $revisionReview) { review in
            RevisionActionsSheet(review: review, root: tab.id, current: snapshot.repository.branch, otherWorktree: snapshot.otherWorktree, addFromGraph: pickMoreCommits) {
                performBranchAction(.revision($0))
            }
            .zoomAppDialog()
        }
    }

    private var current: RepositoryReference? {
        snapshot.checkedOutBranch
    }

    private var commandBar: some View {
        HStack(spacing: 9) {
            Menu {
                ForEach(repoTabs) { other in Button(other.title) { selectTab(other.id) } }
                Divider()
                Button("Add Repository…", action: openRepository)
            } label: { Text(tab.title) }
            .modifier(SelectorStyle(caption: "Repository", value: tab.title))
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            Menu {
                if let current {
                    Button("Show Checked-Out Branch in Graph", systemImage: "scope") { selectReference(current) }
                    Divider()
                }
                ForEach(snapshot.references.filter { $0.kind == .local }) { ref in
                    Button { checkout(ref) } label: {
                        if snapshot.isCheckedOut(ref) { Label(ref.name, systemImage: "checkmark") }
                        else { Text(ref.name) }
                    }
                    .disabled(!canMoveBranches)
                }
            } label: {
                Text(snapshot.repository.branch).lineLimit(1).truncationMode(.middle)
            }
            .modifier(SelectorStyle(caption: current == nil && snapshot.repository.headID != nil ? "Revision" : "Checked out",
                                    value: snapshot.repository.branch))
            .help(snapshot.repository.branch)
            Spacer(minLength: 4)
            Group {
                barButton("Undo", "arrow.uturn.backward", "Undo the last branch switch", enabled: valid(tab.switchUndo)) {
                    if let step = tab.switchUndo { performBranchAction(step.action) }
                }
                barButton("Redo", "arrow.uturn.forward", "Redo the branch switch", enabled: valid(tab.switchRedo)) {
                    if let step = tab.switchRedo { performBranchAction(step.action) }
                }
                barButton("Pull", "arrow.down.to.line", "Fast-forward from the upstream branch", enabled: canMoveBranches && current?.upstreamID != nil) { if let current { performBranchAction(.pull(current)) } }
                barButton("Push", "arrow.up.to.line", pushHelp(for: toolbarPushBranch), enabled: canMoveBranches && toolbarPushBranch != nil) {
                    if let branch = toolbarPushBranch { requestPush(branch) }
                }
                barButton("Branch", "arrow.triangle.branch", "Create a branch at HEAD", enabled: canMoveBranches && current != nil) {
                    if let current { nameBranch(.create(current)) }
                }
                barButton("Merge", RevisionOperation.merge.icon, "Merge one branch into another",
                          enabled: canMoveBranches && snapshot.canMergeBranches()) {
                    if let selectedReference, tab.historySelection == .commit(selectedReference.commitID),
                       snapshot.canMergeBranches(from: selectedReference) {
                        showMerge(from: selectedReference)
                    } else {
                        showMerge()
                    }
                }
                barButton("Tag", "tag", "Create a tag at the current commit", enabled: canTagHead, action: tagHead)
                barButton("Stash", "tray.and.arrow.down", "Stash tracked and untracked changes", enabled: canMoveBranches && !snapshot.repository.changes.isEmpty && !hasConflicts) { performBranchAction(.stash) }
                barButton("Pop", "tray.and.arrow.up", "Apply the latest stash", enabled: canMoveBranches && !snapshot.stashes.isEmpty && !hasConflicts) {
                    if let latest = snapshot.stashes.first { performBranchAction(.stashEntry(.pop, latest)) }
                }
            }
            Divider().frame(height: 29)
            barButton("Terminal", "terminal", "Open Terminal in this repository") {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    NSWorkspace.shared.open([tab.id], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                }
            }
            Spacer(minLength: 4)
            Menu {
                if let current {
                    Button("Branch Actions…", systemImage: "arrow.triangle.branch") { showActions(RevisionPoint(current)) }
                        .disabled(!canMoveBranches)
                }
                Button("Fetch All Remotes", systemImage: "arrow.down.to.line") { performBranchAction(.fetch) }.disabled(!canChangeBranch)
                Button("Refresh Repository", action: refresh).disabled(!canChangeBranch)
                Button("Reveal Repository in Finder") { NSWorkspace.shared.activateFileViewerSelecting([tab.id]) }
                Button("Copy Repository Path") { copyGitText(tab.id.path) }
            } label: { barLabel("Actions", "slider.horizontal.3") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            barButton("Search", "magnifyingglass", "Search all branches by commit message") { searching.toggle() }
                .popover(isPresented: $searching) {
                    CommitSearch(root: tab.id) { commit in
                        tab.diff = nil
                        tab.commitJump = CommitJump(commitID: commit.id)
                        searching = false
                    }
                    .zoomAppDialog()
                }
        }
        .padding(.horizontal, 12).frame(height: 46)
        .background(WorkspaceColors.panel)
        .confirmationDialog("Push “" + (pushBranch?.name ?? "") + "” to “" + (pushBranch?.upstreamTarget?.displayName ?? "") + "”?", isPresented: Binding(
            get: { pushBranch != nil }, set: { if !$0 { pushBranch = nil } }
        ), titleVisibility: .visible, presenting: pushBranch) { branch in
            Button("Push") { performBranchAction(.push(branch)) }
        }
    }

    private var canTagHead: Bool { canMoveBranches && snapshot.repository.headID != nil }

    private func tagHead() {
        guard canTagHead, let head = snapshot.repository.headID else { return }
        tagTarget = current.map(RevisionPoint.init) ?? RevisionPoint(commit: head)
    }

    private var toolbarPushBranch: RepositoryReference? {
        if let ref = selectedReference, ref.kind == .local, tab.historySelection != .workInProgress { return ref }
        return current
    }

    private func pushHelp(for branch: RepositoryReference?) -> String {
        if snapshot.repository.headID == nil && branch == nil { return "Create the first commit to push this branch" }
        guard let branch else { return "Select a local branch to push" }
        if let upstream = branch.pushUpstream { return "Push “" + branch.name + "” to " + upstream.displayName }
        if snapshot.remotes.count == 1 { return "Publish “" + branch.name + "” to " + snapshot.remotes[0] }
        return "Choose a remote to publish “" + branch.name + "”"
    }

    private func requestPush(_ branch: RepositoryReference) {
        guard canMoveBranches, branch.kind == .local else { return }
        if branch.pushUpstream != nil {
            pushBranch = branch
        } else if branch.upstreamID == nil, snapshot.remotes.count == 1, let remote = snapshot.remotes.first {
            performBranchAction(.publish(branch, remote: remote))
        } else {
            publishBranch = branch
        }
    }

    private func valid(_ step: SwitchStep?) -> Bool {
        canMoveBranches && step != nil && step?.from == snapshot.repository.branch && step?.head == snapshot.repository.headID
    }

    private func barLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 10))
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
        }
        .frame(minWidth: 32, minHeight: 38).contentShape(Rectangle())
    }

    private func barButton(_ title: String, _ symbol: String, _ help: String, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(title, symbol) }.buttonStyle(.plain).disabled(!enabled).help(help)
    }

    private var hasConflicts: Bool {
        snapshot.repository.changes.contains { $0.staged == .conflict }
    }

    private var canMoveBranches: Bool {
        canChangeBranch && snapshot.repository.integration == nil && tab.pendingCommitBatch == nil
    }

    private var namingBranch: Binding<Bool> {
        Binding(get: { branchDraft != nil }, set: { if !$0 { branchDraft = nil } })
    }

    private var trimmedBranchName: String {
        newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var branchNameTaken: Bool {
        snapshot.references.contains { $0.kind == .local && $0.name == trimmedBranchName }
    }

    private func nameBranch(_ draft: BranchDraft) {
        newBranchName = draft.suggestedName
        branchDraft = draft
    }

    @ViewBuilder
    private func diffView(_ diff: DiffSelection) -> some View {
        if diff.request.source == .workingTree(.conflict), let integration = snapshot.repository.integration {
            ConflictDiffView(request: diff.request, integration: integration, branch: snapshot.repository.branch,
                             snapshotID: snapshot.id, busy: !canChangeBranch,
                             save: { performBranchAction(.resolve($0, $1)) }, close: { tab.diff = nil })
                .id(diff.request.id)
        } else {
            DiffView(selection: diff, snapshotID: snapshot.id, chooseSource: chooseDiffSource, close: { tab.diff = nil })
                .id(diff.request.id)
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            HistoryView(snapshot: snapshot, selectedReference: selectedReference, pendingCommitBatch: tab.pendingCommitBatch, resumeBatchReview: resumeBatchReview, selection: $tab.historySelection,
                        jump: $tab.commitJump, worktreeFileCommit: tab.worktreeFileCommit, onSelectReference: selectReference, onCheckout: checkout, onTrack: { nameBranch(.track($0)) }, onPush: requestPush, onDrop: proposeDrop, openBatch: { commitBatch = $0 }, openActions: { source, preferred in showActions(source, preferred: preferred) }, createTag: { tagTarget = $0 }, canAct: canMoveBranches, referenceMenu: referenceActions, deletionChoices: deletionChoices, requestDelete: { deleting = $0 },
                        showsDiff: tab.diff != nil, center: { if let diff = tab.diff { diffView(diff) } },
                        worktree: {
                            WorktreePanel(repository: snapshot.repository, branchColor: snapshot.colors.currentBranchColor,
                                          draft: $tab.commitDraft, branch: current, remotes: snapshot.remotes,
                                          canCombine: canMoveBranches && (current != nil || snapshot.repository.headID == nil),
                                          busy: !canChangeBranch, canPush: canMoveBranches && current != nil, pushHelp: pushHelp(for: current),
                                          push: { if let current { requestPush(current) } },
                                          openChange: openWorkingTreeDiff,
                                          perform: { performBranchAction(.worktree($0)) })
                        }) { source, file in
                let request = DiffRequest(root: tab.id, path: file.path,
                                          originalPath: file.originalPath, source: source)
                tab.diff = DiffSelection(request: request, sources: [source])
            }
        }
    }

    private func openWorkingTreeDiff(_ change: FileChange, preferred: DiffRequest.Source?) {
        var sources: [DiffRequest.Source] = []
        if let staged = change.staged, staged != .conflict {
            sources.append(.staged)
        }
        if let status = change.workingTree {
            sources.append(.workingTree(status))
        }
        guard let source = preferred.flatMap({ sources.contains($0) ? $0 : nil }) ?? sources.last else { return }

        let request = DiffRequest(root: tab.id, path: change.path, originalPath: change.originalPath, source: source)
        tab.diff = DiffSelection(request: request, sources: sources)
    }

    private func chooseDiffSource(_ source: DiffRequest.Source) {
        guard let diff = tab.diff, diff.request.source != source else { return }
        let current = diff.request
        let request = DiffRequest(root: current.root, path: current.path,
                                  originalPath: current.originalPath, source: source)
        tab.diff = DiffSelection(request: request, sources: diff.sources)
    }

    private var selectedReference: RepositoryReference? {
        guard case .reference(let id) = tab.selection else { return nil }
        return snapshot.references.first { $0.id == id }
    }

    private var sidebar: some View {
        let query = tab.referenceFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = snapshot.referenceBadges.filter { badge in
            query.isEmpty || badge.name.localizedStandardContains(query) || badge.references.contains { $0.name.localizedStandardContains(query) }
        }

        return VStack(spacing: 0) {
            referenceSearch

            WorkspaceScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    navigationRow("All Commits", icon: "clock.arrow.circlepath", selection: .history)
                    navigationRow("Pull Requests", icon: "arrow.triangle.pull", selection: .pullRequests)
                    let branches = matches.filter { $0.reference.kind != .tag }
                    let tags = matches.filter { $0.reference.kind == .tag }
                    if !branches.isEmpty {
                        referenceGroup(.local, badges: branches, isFiltering: !query.isEmpty)
                    }
                    if !tags.isEmpty || query.isEmpty {
                        referenceGroup(.tag, badges: tags, isFiltering: !query.isEmpty)
                    }
                    sidebarGroup("Worktrees", "externaldrive", count: snapshot.worktrees.count, expanded: sectionExpansion("worktrees")) {
                        ForEach(snapshot.worktrees) { item in
                            Button { openWorktree(item.id) } label: {
                                Label(item.branch, systemImage: item.id.standardizedFileURL == tab.id.standardizedFileURL ? "house" : "externaldrive")
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).help(item.id.path).padding(.leading, 8).frame(minHeight: 24)
                            .contextMenu {
                                if let ref = snapshot.references.first(where: { $0.kind == .local && $0.name == item.branch }) {
                                    deletionMenu(ref)
                                }
                            }
                        }
                    }
                    sidebarGroup("Stashes", "tray", count: snapshot.stashes.count, expanded: sectionExpansion("stashes")) {
                        ForEach(snapshot.stashes, id: \.self) { stash in
                            let selected = tab.historySelection == .stash(stash.id)
                            Button {
                                tab.diff = nil
                                tab.selection = .history
                                tab.commitJump = nil
                                tab.historySelection = .stash(stash.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "tray.full")
                                    Text(stash.selector).font(.caption.monospacedDigit())
                                    Text(stash.subject).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 8).frame(minHeight: 24).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .background(selected ? WorkspaceColors.selection : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityAddTraits(selected ? .isSelected : []).help(stash.subject)
                            .contextMenu { stashActions(stash) }
                        }
                    }
                    if !query.isEmpty && matches.isEmpty {
                        Text("No matching branches or tags.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
            }

            Label(snapshot.repository.root.path, systemImage: "folder")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .help(snapshot.repository.root.path)
        }
        .background(WorkspaceColors.sidebar)
    }

    @ViewBuilder
    private func stashActions(_ stash: GitStash) -> some View {
        Button("Apply Stash", systemImage: "tray.and.arrow.down") { performBranchAction(.stashEntry(.apply, stash)) }
            .disabled(!canMoveBranches || hasConflicts)
        Button("Pop Stash", systemImage: "tray.and.arrow.up") { performBranchAction(.stashEntry(.pop, stash)) }
            .disabled(!canMoveBranches || hasConflicts)
        Divider()
        Button("Delete Stash…", systemImage: "trash", role: .destructive) { stashToDelete = stash }
            .disabled(!canChangeBranch)
    }

    @ViewBuilder
    private func sidebarGroup<Rows: View, HeaderMenu: View>(_ title: String, _ icon: String, count: Int,
                                          expanded: Binding<Bool>, @ViewBuilder headerMenu: () -> HeaderMenu = { EmptyView() },
                                          @ViewBuilder rows: () -> Rows) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").frame(width: 10)
                Image(systemName: icon).frame(width: 14)
                Text(title.uppercased())
                Spacer()
                Text(count, format: .number).monospacedDigit()
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.top, 3)
        .accessibilityLabel(title + ", " + String(count))
        .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
        .contextMenu { headerMenu() }
        if expanded.wrappedValue { rows() }
    }

    private func navigationRow(_ title: String, icon: String, selection: RepositorySelection) -> some View {
        let isStash: Bool = { if case .stash = tab.historySelection { return true }; return false }()
        return Button {
            if isStash && selection == .history {
                if let head = snapshot.repository.headID { tab.commitJump = CommitJump(commitID: head) }
                else { tab.showWorkInProgress() }
            }
            tab.selection = selection
            tab.diff = nil
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(tab.selection == selection && (!isStash || selection == .pullRequests) ? WorkspaceColors.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var referenceSearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Filter branches and tags", text: $tab.referenceFilter)
                .textFieldStyle(.plain)
                .lineLimit(1)

            if !tab.referenceFilter.isEmpty {
                Button {
                    tab.referenceFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear branch filter")
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(height: 27)
        .background(WorkspaceColors.history, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(WorkspaceColors.divider)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func sectionExpansion(_ key: String, defaultExpanded: Bool = false) -> Binding<Bool> {
        Binding(get: { tab.sidebarSections[key] ?? defaultExpanded },
                set: { tab.sidebarSections[key] = $0 })
    }

    private func referenceGroup(_ kind: RepositoryReference.Kind, badges: [GraphReferenceBadge],
                                isFiltering: Bool) -> some View {
        let saved = sectionExpansion(kind.prefix, defaultExpanded: true)
        let isExpanded = Binding {
            isFiltering ? !collapsedSearchGroups.contains(kind) : saved.wrappedValue
        } set: { expanded in
            saved.wrappedValue = expanded
            if isFiltering {
                if expanded { collapsedSearchGroups.remove(kind) }
                else { collapsedSearchGroups.insert(kind) }
            }
        }
        return sidebarGroup(kind == .tag ? "Tags" : "Branches",
                            kind.icon, count: badges.count, expanded: isExpanded, headerMenu: {
            if kind == .tag {
                Button("Create Tag…", systemImage: "tag", action: tagHead).disabled(!canTagHead)
            }
        }) {
            ForEach(badges) { badge in referenceLabel(badge) }
        }
    }

    private func referenceLabel(_ badge: GraphReferenceBadge) -> some View {
        let ref = badge.reference
        let isCurrent = snapshot.isCheckedOut(ref)
        let selected = badge.references.contains { tab.selection == .reference($0.id) }
        return HStack(spacing: 4) {
            BranchLocationLabel(badge: badge, repository: tab.id, checkedOut: isCurrent,
                                select: selectReference, checkout: checkout, drop: proposeDrop, menu: referenceActions)
            if isCurrent {
                Spacer(minLength: 2)
                Text("Current")
                    .font(.caption2.weight(.bold)).fixedSize()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(snapshot.colors.currentBranchColor.opacity(0.16), in: Capsule())
            }
        }
        .fontWeight(isCurrent ? .semibold : .regular)
        .foregroundStyle(snapshot.colors.color(for: ref))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? WorkspaceColors.selection : .clear)
                .modifier(BranchDragControl(reference: ref, repository: tab.id, onSelect: selectReference, onCheckout: checkout, onDrop: proposeDrop))
                .contextMenu { referenceActions(ref) }
                .accessibilityHidden(true)
        }
    }

    private func selectReference(_ reference: RepositoryReference) {
        tab.selectReference(reference)
    }

    private func checkout(_ reference: RepositoryReference) {
        guard canMoveBranches else { return }
        if let local = snapshot.checkoutBranch(for: reference) {
            if snapshot.isCheckedOut(local) { selectReference(local) }
            else { performBranchAction(.switchTo(local.name)) }
        } else if reference.kind == .remote {
            nameBranch(.track(reference))
        }
    }

    private func pickMoreCommits(_ batch: CommitBatch) {
        tab.pendingCommitBatch = batch
        tab.diff = nil
        tab.commitJump = nil
        tab.historySelection = nil
        commitBatch = nil
        revisionReview = nil
    }

    private func resumeBatchReview() {
        commitBatch = tab.pendingCommitBatch
        tab.pendingCommitBatch = nil
    }

    private func proposeDrop(_ drag: BranchDrag, onto target: RevisionPoint) -> Bool {
        guard canMoveBranches, drag.repository == tab.id, drag.canDrop(on: target) else { return false }
        if drag.commits.count > 1 {
            guard target.isLocal else { return false }
            let locals = snapshot.references.filter { $0.kind == .local }.map(RevisionPoint.init)
            commitBatch = CommitBatch(commits: drag.commits, target: target, localBranches: locals)
            return true
        }
        showActions(drag.source, target: target, preferred: drag.source.reference == nil ? .cherryPick : (drag.source.isLocal && target.isRemote ? .push : nil))
        return true
    }

    private func showMerge(from source: RepositoryReference? = nil) {
        guard canMoveBranches, snapshot.canMergeBranches(from: source) else { return }
        mergeReview = BranchMergeReview(branches: snapshot.references, source: source, destination: current)
    }

    private func showActions(_ source: RevisionPoint, target: RevisionPoint? = nil, preferred: RevisionOperation? = nil) {
        guard canMoveBranches else { return }
        if preferred == .merge, target == nil, let reference = source.reference, reference.kind != .tag {
            showMerge(from: reference)
            return
        }
        var targets = snapshot.references.map(RevisionPoint.init)
        if let target, !targets.contains(where: { $0.id == target.id }) { targets.insert(target, at: 0) }
        let upstream = targets.first { $0.id == source.reference?.upstreamID && source.reference?.pushUpstream != nil }
        let prefersUpstream = preferred?.pushes == true || (preferred == nil && source.reference?.id == current?.id)
        guard let destination = target ?? (prefersUpstream ? upstream : nil)
                ?? current.map(RevisionPoint.init) ?? targets.first(where: \.isLocal) ?? targets.first else { return }
        revisionReview = RevisionReview(source: source, initialTarget: destination, targets: targets, preferred: preferred)
    }

    @ViewBuilder
    private func referenceActions(_ reference: RepositoryReference) -> some View {
        if reference.kind == .local {
            Button(reference.pushUpstream == nil ? "Publish Branch" : "Push Branch", systemImage: "arrow.up.to.line") {
                requestPush(reference)
            }.disabled(!canMoveBranches)
        }
        if reference.kind != .tag {
            Button("Merge “" + reference.name + "” into…", systemImage: RevisionOperation.merge.icon) {
                showMerge(from: reference)
            }.disabled(!canMoveBranches || !snapshot.canMergeBranches(from: reference))
        }
        Button("Branch Actions…", systemImage: "arrow.triangle.branch") { showActions(RevisionPoint(reference)) }
            .disabled(!canMoveBranches)
        if reference.kind == .local, let upstream = snapshot.references.first(where: { $0.id == reference.upstreamID }) {
            Button("Force Push with Lease…", systemImage: "arrow.up.to.line") {
                showActions(RevisionPoint(reference), target: RevisionPoint(upstream), preferred: .forcePush)
            }.disabled(!canMoveBranches)
        }
        if let current {
            Button("Cherry-pick Tip onto " + current.name + "…", systemImage: "arrow.down.to.line") {
                showActions(RevisionPoint(commit: reference.commitID), target: RevisionPoint(current), preferred: .cherryPick)
            }.disabled(!canMoveBranches || reference.commitID == current.commitID)
        }
        if let destination = current ?? snapshot.references.first(where: { $0.kind == .local }) {
            Button("Revert Tip Commit on “" + destination.name + "”…", systemImage: RevisionOperation.revert.icon) {
                showActions(RevisionPoint(reference), target: RevisionPoint(destination), preferred: .revert)
            }.disabled(!canMoveBranches)
            Button("Reset “" + destination.name + "” to This Tip…", systemImage: RevisionOperation.reset.icon) {
                showActions(RevisionPoint(reference), target: RevisionPoint(destination), preferred: .reset)
            }.disabled(!canMoveBranches)
        }
        Divider()
        if let local = snapshot.checkoutBranch(for: reference) {
            Button(snapshot.checkoutTitle(for: local), systemImage: "arrow.triangle.branch") { checkout(reference) }
                .disabled(!canMoveBranches || snapshot.isCheckedOut(local))
        } else if reference.kind == .remote {
            Button("Create Tracking Branch…", systemImage: "arrow.triangle.branch") { checkout(reference) }
                .disabled(!canMoveBranches)
        }

        if reference.kind != .tag, let current, current.id != reference.id {
            Button("Rebase \(current.name) onto This Branch…", systemImage: "arrow.turn.up.right") {
                showActions(RevisionPoint(current), target: RevisionPoint(reference), preferred: .rebase)
            }
            .disabled(!canMoveBranches)
        }

        Button("Create Tag Here…", systemImage: "tag") { tagTarget = RevisionPoint(reference) }
            .disabled(!canMoveBranches)
        if reference.kind == .tag && !snapshot.remotes.isEmpty {
            Menu("Push Tag to…") {
                ForEach(snapshot.remotes, id: \.self) { remote in
                    Button(remote) { performBranchAction(.pushTag(reference, remote: remote)) }
                }
            }.disabled(!canMoveBranches)
        }
        Button("Create Branch from Here…", systemImage: "plus") {
            nameBranch(.create(reference))
        }
        .disabled(!canMoveBranches)
        Divider()
        Button(reference.kind == .tag ? "Jump to Tagged Commit" : "Jump to Branch Tip",
               systemImage: "scope") {
            tab.selection = .reference(reference.id)
            tab.diff = nil
            tab.commitJump = CommitJump(commitID: reference.commitID)
        }
        Button(reference.kind == .tag ? "Copy Tag Name" : "Copy Branch Name",
               systemImage: "doc.on.doc") {
            copy(reference.name)
        }
        Button("Copy Commit Hash", systemImage: "number") {
            copy(reference.commitID)
        }
        if reference.kind != .tag {
            Divider()
            deletionMenu(reference)
        }
    }

    private func deletionChoices(_ ref: RepositoryReference) -> [BranchDeletion] {
        canMoveBranches ? BranchDeletion.choices(for: ref, in: snapshot) : []
    }

    private func deletionMenu(_ ref: RepositoryReference) -> some View {
        let choices = deletionChoices(ref)
        return Menu("Delete…") {
            ForEach(choices) { choice in
                Button(choice.title + "…", role: .destructive) { deleting = choice }
            }
        }.disabled(choices.isEmpty)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }



}

private struct IntegrationBar: View {
    let integration: GitIntegration
    let operation: String?
    let hasConflicts: Bool
    let isBusy: Bool
    let perform: (GitBranchAction) -> Void
    @State private var confirmingAbort = false
    @State private var confirmingSkip = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(operation ?? "\(integration.title) in progress", systemImage: "arrow.triangle.merge")
                    .font(.callout.weight(.semibold))
                if hasConflicts {
                    Text("Select a conflicted file in WIP to resolve it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Continue \(integration.title)") {
                perform(.continueIntegration(integration))
            }
            .disabled(hasConflicts || isBusy)
            if integration != .merge {
                Button("Skip commit…") { confirmingSkip = true }
                    .disabled(isBusy)
                    .confirmationDialog("Skip this commit and its changes?", isPresented: $confirmingSkip, titleVisibility: .visible) {
                        Button("Skip commit", role: .destructive) { perform(.skipIntegration(integration)) }
                        Button("Cancel", role: .cancel) {}
                    }
            }
            Button("Abort…") { confirmingAbort = true }
                .disabled(isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(WorkspaceColors.panel)
        .confirmationDialog("Abort \(integration.title)?", isPresented: $confirmingAbort,
                            titleVisibility: .visible) {
            Button("Abort \(integration.title)", role: .destructive) {
                perform(.abortIntegration(integration))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Git will discard conflict resolutions from this \(integration.rawValue).")
        }
    }
}

private enum BranchDraft {
    case create(RepositoryReference)
    case track(RepositoryReference)

    var title: String {
        switch self {
        case .create: "Create Branch"
        case .track: "Create Tracking Branch"
        }
    }

    var message: String {
        switch self {
        case .create(let reference): "Starts at \(reference.name)."
        case .track(let reference): "Tracks \(reference.name)."
        }
    }

    var suggestedName: String {
        switch self {
        case .create: ""
        case .track(let reference):
            reference.remoteTarget?.name ?? String(reference.name.split(separator: "/", maxSplits: 1).last ?? "")
        }
    }

    func action(named name: String) -> GitBranchAction {
        switch self {
        case .create(let reference): .createAndSwitch(name: name, start: reference)
        case .track(let reference): .track(name: name, remote: reference)
        }
    }
}

private struct HistoryView<ReferenceMenu: View, Center: View, Worktree: View>: View {
    private struct LoadRequest: Equatable {
        let snapshot: UUID
        let maximum: Int
    }

    let snapshot: RepositorySnapshot
    let selectedReference: RepositoryReference?
    let pendingCommitBatch: CommitBatch?
    let resumeBatchReview: () -> Void
    @Binding var selection: HistorySelection?
    @Binding var jump: CommitJump?
    let worktreeFileCommit: String?
    let onSelectReference: (RepositoryReference) -> Void
    let onCheckout: (RepositoryReference) -> Void
    let onTrack: (RepositoryReference) -> Void
    let onPush: (RepositoryReference) -> Void
    let onDrop: (BranchDrag, RevisionPoint) -> Bool
    let openBatch: (CommitBatch) -> Void
    let openActions: (RevisionPoint, RevisionOperation?) -> Void
    let createTag: (RevisionPoint) -> Void
    let canAct: Bool
    let referenceMenu: (RepositoryReference) -> ReferenceMenu
    let deletionChoices: (RepositoryReference) -> [BranchDeletion]
    let requestDelete: (BranchDeletion) -> Void
    let showsDiff: Bool
    @ViewBuilder let center: () -> Center
    @ViewBuilder let worktree: () -> Worktree
    let viewDiff: (DiffRequest.Source, CommitFile) -> Void

    @AppStorage("historyInspectorWidth") private var savedInspectorWidth: Double = 0
    @AppStorage("historyBranchTagWidth") private var branchTagWidth: Double = 0
    @State private var draggingBranchTag: CGFloat?
    @State private var dragWidth: Double?
    @State private var graph: CommitGraph?
    @State private var maximum = GitHistory.pageSize
    @State private var loadedMaximum = 0
    @State private var loadedSnapshot: UUID?
    @State private var scrollRequest: CommitJump?
    @State private var error: String?

    var body: some View {
        Group {
            if let graph, graph.hasWorkingTree || !graph.rows.isEmpty || !snapshot.stashes.isEmpty {
                GeometryReader { geometry in
                    let maximumWidth = max(190, geometry.size.width - 188)
                    let preferred = savedInspectorWidth > 0 ? savedInspectorWidth : max(294, geometry.size.width * 0.245)
                    let width = min(max(190, dragWidth ?? preferred), maximumWidth)
                    HStack(spacing: 0) {
                        Group {
                            if showsDiff && pendingCommitBatch == nil { center() } else { commitList(graph) }
                        }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        WidthDivider(label: "Inspector width", width: width, limits: 190...maximumWidth, growsLeft: true, resize: { proposed, finished in
                            if finished {
                                savedInspectorWidth = proposed
                                dragWidth = nil
                            } else {
                                dragWidth = proposed
                            }
                        })
                        .frame(width: 8)
                        inspector(graph)
                            .frame(width: width)
                            .frame(maxHeight: .infinity)
                            .background(WorkspaceColors.sidebar)
                    }
                }
            } else if let error {
                GitErrorDetails(title: "Couldn’t load commit history", message: error)
                    .frame(maxWidth: 560).padding()
            } else if graph != nil {
                ContentUnavailableView("No Commits Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Your first file changes will appear here as WIP."))
            } else {
                ProgressView("Reading commit history…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let draft = pendingCommitBatch { batchSelectionBar(draft) }
        }
        .task(id: LoadRequest(snapshot: snapshot.id, maximum: maximum)) {
            await loadHistory(maximum: maximum)
        }
        .onChange(of: jump) {
            focusBranchTip()
        }
    }

    private func batchSelectionBar(_ draft: CommitBatch) -> some View {
        let ids: [String]
        switch selection {
        case .commit(let id): ids = [id]
        case .commits(let selected): ids = selected
        default: ids = []
        }
        let selected = graph.map { graph in ids.compactMap { id in graph.indexByID[id].map { graph.rows[$0].commit } } } ?? []
        let additions = draft.newCommits(in: selected)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Select commits to append", systemImage: "plus").font(.callout.weight(.semibold))
                Text(draft.countLabel + " queued · " + draft.target.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Back to review", action: resumeBatchReview)
            Button(additions.isEmpty ? "Add selected" : "Add " + String(additions.count) + (additions.count == 1 ? " commit" : " commits")) {
                draft.append(selected)
                resumeBatchReview()
            }
            .buttonStyle(.borderedProminent).disabled(additions.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 7).background(WorkspaceColors.panel)
    }

    private func loadHistory(maximum: Int) async {
        do {
            let root = snapshot.repository.root
            let dirty = !snapshot.repository.changes.isEmpty
            let head = snapshot.repository.headID
            let tipColors = snapshot.colors.byTip
            let loaded = try await Task.detached(priority: .userInitiated) {
                CommitGraph(commits: try await GitHistory.commits(in: root, maximum: maximum), hasWorkingTree: dirty, head: head, tipColors: tipColors)
            }.value
            guard !Task.isCancelled else { return }
            graph = loaded
            loadedMaximum = maximum
            loadedSnapshot = snapshot.id
            error = nil
            switch selection {
            case .stash(let id) where snapshot.stashes.contains(where: { $0.id == id }): break
            case .workInProgress where dirty: break
            case .commit(let id) where loaded.indexByID[id] != nil: break
            case .commits(let ids):
                let selected = Set(ids)
                let ordered = loaded.rows.reversed().compactMap { selected.contains($0.id) ? $0.id : nil }
                selection = HistorySelection.selectedCommits(ordered)
            default: selection = dirty ? .workInProgress : loaded.rows.first.map { .commit($0.id) }
            }
            focusBranchTip()
        } catch {
            guard !Task.isCancelled else { return }
            graph = nil
            self.error = error.localizedDescription
        }
    }

    private func focusBranchTip() {
        guard let jump, let graph, loadedSnapshot == snapshot.id, loadedMaximum == maximum else { return }
        if graph.indexByID[jump.commitID] != nil {
            selection = .commit(jump.commitID)
            scrollRequest = jump
            self.jump = nil
        } else if graph.rows.count == maximum {
            maximum += GitHistory.pageSize
        } else {
            self.jump = nil
        }
    }

    private func commitList(_ graph: CommitGraph) -> some View {
        GeometryReader { geo in
            let columns = HistoryColumns(width: geo.size.width, lanes: graph.laneCount,
                                         preferredRefs: draggingBranchTag ?? branchTagWidth)
            VStack(spacing: 0) {
                HistoryColumnHeader(columns: columns)
                    .overlay(alignment: .leading) {
                        WidthDivider(label: "Branch / Tag column width", width: columns.refs, limits: columns.refLimits) { value, finished in
                            if finished { branchTagWidth = value; draggingBranchTag = nil }
                            else { draggingBranchTag = value }
                        }.frame(width: 8).offset(x: columns.refs - 4)
                    }
                CommitTable(graph: graph, columns: columns, snapshot: snapshot, selection: $selection, jump: scrollRequest,
                            deletionChoices: deletionChoices, requestDelete: requestDelete, openActions: openActions, openBatch: openBatch, createTag: createTag, canAct: canAct, onDrop: onDrop, expandedBadges: expandedBadges) { references in
                    BranchBadges(groups: references, snapshot: snapshot, badge: referenceBadge, actions: referenceMenu)
                }
                if graph.rows.count == loadedMaximum {
                    Button(loadedMaximum == maximum ? "Load Older Commits" : "Loading Older Commits…") {
                        maximum += GitHistory.pageSize
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WorkspaceColors.accent)
                    .disabled(loadedMaximum != maximum)
                    .padding(6)
                }
            }
        }
        .background(WorkspaceColors.history)
    }

    private func locationLabel(_ badge: GraphReferenceBadge, wraps: Bool = false) -> some View {
        BranchLocationLabel(badge: badge, repository: snapshot.repository.root, checkedOut: snapshot.isCheckedOut(badge.reference),
                            wraps: wraps, select: onSelectReference, checkout: onCheckout, drop: onDrop, menu: referenceMenu)
    }

    private func expandedBadges(_ badges: [GraphReferenceBadge], width: CGFloat) -> AnyView {
        let atHead = badges.contains { snapshot.isCheckedOut($0.reference) }
        let tint = atHead ? Color(red: 0.03, green: 0.55, blue: 0.66)
                          : badges.first.map { snapshot.colors.color(for: $0.reference) } ?? WorkspaceColors.accent
        return AnyView(LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(badges) { badge in
                let ref = badge.reference
                let current = snapshot.isCheckedOut(ref)
                HStack(spacing: 5) {
                    locationLabel(badge, wraps: true)
                    Spacer(minLength: 0)
                    if ref.kind == .local && !current {
                        Button(snapshot.otherWorktree(for: ref.name) == nil ? "Switch" : "Open") { onCheckout(ref) }
                            .controlSize(.mini).fixedSize().disabled(!canAct)
                            .accessibilityLabel(snapshot.checkoutTitle(for: ref)).help(snapshot.checkoutTitle(for: ref))
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(current ? 1 : 0.87))
                .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: GraphReferencePreview.rowHeight, alignment: .leading)
                .background {
                    GraphReferenceRowBackground(badge: badge, tint: tint.opacity(current ? 0.64 : 0.27))
                        .modifier(BranchDragControl(reference: ref, repository: snapshot.repository.root,
                                                    onSelect: onSelectReference, onCheckout: onCheckout, onDrop: onDrop))
                        .contextMenu { referenceMenu(ref) }
                        .accessibilityHidden(true)
                }
            }
        }.background(WorkspaceColors.history))
    }

    private func referenceBadge(_ badge: GraphReferenceBadge) -> some View {
        let current = snapshot.isCheckedOut(badge.reference)
        let color = snapshot.colors.color(for: badge.reference)
        return locationLabel(badge)
            .font(.system(size: 11, weight: current ? .semibold : .medium))
            .foregroundStyle(current ? Color.white : color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(current ? Color(red: 0.05, green: 0.24, blue: 0.49) : color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func inspector(_ graph: CommitGraph) -> some View {
        if case .stash(let id) = selection, let stash = snapshot.stashes.first(where: { $0.id == id }) {
            StashInspector(stash: stash, root: snapshot.repository.root, open: viewDiff).id(stash.id)
        } else if selection == .workInProgress, graph.hasWorkingTree {
            worktree()
        } else if case .commits(let ids) = selection {
            let commits = ids.compactMap { id in graph.indexByID[id].map { graph.rows[$0].commit } }
            VStack(alignment: .leading, spacing: 10) {
                Text("\(commits.count) commits selected").font(.headline)
                if pendingCommitBatch == nil {
                    Text("Right-click the selection to cherry-pick or revert these commits.").font(.callout).foregroundStyle(.secondary)
                }
                OrderedCommitList(commits: commits)
            }.padding(12).frame(maxHeight: .infinity, alignment: .top)
        } else if case .commit(let id) = selection, let index = graph.indexByID[id] {
            let commit = graph.rows[index].commit
            let refs = snapshot.references.filter { $0.commitID == id }
            CommitInspector(root: snapshot.repository.root, commit: commit, references: snapshot.references, showAll: worktreeFileCommit == id, branchInfo: {
                if let ref = refs.first(where: { $0.id == selectedReference?.id }) ?? refs.first(where: snapshot.isCheckedOut) ?? refs.first {
                    GraphBranchInspector(reference: ref, atCommit: refs, snapshot: snapshot, canAct: canAct,
                                         select: onSelectReference, checkout: onCheckout, track: onTrack, push: onPush, merge: { openActions(RevisionPoint($0), .merge) })
                }
            }) { file in
                viewDiff(file.unchanged ? .unchanged(commit) : .commit(commit), file)
            }
            .id(commit.id + (worktreeFileCommit == id ? "-all" : ""))
        } else {
            ContentUnavailableView("Select a Commit", systemImage: "sidebar.right")
        }
    }
}

private struct CommitInspector<BranchInfo: View>: View {
    let root: URL
    let commit: GitCommit
    let references: [RepositoryReference]
    @ViewBuilder let branchInfo: () -> BranchInfo
    let viewDiff: (CommitFile) -> Void

    @AppStorage(PreferenceKey.historyTree) private var tree = true
    @AppStorage(PreferenceKey.historyDescending) private var descending = false
    @State private var all = false
    @State private var files: [CommitFile] = []
    @State private var displayed: FileHierarchy<CommitFile>?
    @State private var expanded: Set<String> = []
    @State private var error: String?

    init(root: URL, commit: GitCommit, references: [RepositoryReference], showAll: Bool,
         @ViewBuilder branchInfo: @escaping () -> BranchInfo, viewDiff: @escaping (CommitFile) -> Void) {
        self.root = root
        self.commit = commit
        self.references = references
        self.branchInfo = branchInfo
        self.viewDiff = viewDiff
        _all = State(initialValue: showAll)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("commit:  " + commit.shortID).font(.caption.monospaced())
                .frame(maxWidth: .infinity).frame(height: 30)
                .contextMenu {
                    Button("Copy Commit SHA") { copyGitText(commit.id) }
                    Button("Copy Commit Summary") { copyGitText(commit.subject) }
                }
            Divider()
            WorkspaceScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    branchInfo()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(commit.subject).font(.headline)
                        if !commit.message.isEmpty { Text(commit.message).font(.callout) }
                    }.textSelection(.enabled).padding(10)
                    .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
                    .background(WorkspaceColors.history.opacity(0.66), in: RoundedRectangle(cornerRadius: 3))
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(WorkspaceColors.divider) }
                    HStack(spacing: 7) {
                        Text(commit.authorInitials).font(.caption.bold())
                            .frame(width: 33, height: 33).background(Color.cyan.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commit.author).font(.callout.weight(.medium))
                            if let date = commit.date {
                                Text("authored " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !commit.parents.isEmpty {
                        DisclosureGroup(commit.parents.count > 1 ? commit.mergeRoute ?? "Merge parents" : "Parent " + String(commit.parents[0].prefix(7))) {
                            ForEach(Array(commit.parents.enumerated()), id: \.offset) { i, parent in
                                let names = references.filter { $0.commitID == parent }.map(\.name).joined(separator: ", ")
                                Text("\(i == 0 ? "First parent" : "Merged in") · \(parent.prefix(7)) \(names)")
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.font(.caption).foregroundStyle(commit.parents.count > 1 ? Color.mint : .secondary)
                    }
                    if let displayed {
                        let counts = Dictionary(grouping: files, by: \.status)
                        HStack(spacing: 7) {
                            ForEach(counts.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { status in
                                Label("\(counts[status]?.count ?? 0) \(status.rawValue.lowercased())", systemImage: status.icon)
                                    .foregroundStyle(statusColor(status))
                            }
                            if files.isEmpty { Text("No changed files").foregroundStyle(.secondary) }
                        }.font(.caption).padding(.top, 6)
                        ViewThatFits(in: .horizontal) {
                            HStack { layoutControls; Spacer(minLength: 2); allToggle }
                            VStack(alignment: .leading, spacing: 5) { layoutControls; allToggle }
                        }
                        Divider()
                        if tree && !displayed.folders.isEmpty {
                            let allExpanded = Set(displayed.folders.keys).isSubset(of: expanded)
                            Button(allExpanded ? "Collapse All" : "Expand All") { expanded = allExpanded ? [] : Set(displayed.folders.keys) }
                                .buttonStyle(.plain).font(.caption)
                        }
                        ForEach(displayed.rows(tree: tree, descending: descending, expanded: expanded)) { row in
                            fileRow(row)
                        }
                    } else if let error { GitErrorDetails(title: "Couldn’t read changed files", message: error) }
                    else { ProgressView().controlSize(.small) }
                }.padding(10)
            }
        }
        .task(id: all) {
            do {
                let changed = try await GitHistory.files(in: root, for: commit)
                let entries = all ? try await GitHistory.allFiles(in: root, for: commit, changes: changed) : changed
                let layout = FileHierarchy(entries, path: \.path)
                try Task.checkCancellation()
                files = changed
                displayed = layout
                error = nil
            } catch {
                if !Task.isCancelled { displayed = nil; self.error = error.localizedDescription }
            }
        }
    }

    private var allToggle: some View { Toggle("View all files", isOn: $all).toggleStyle(.checkbox).font(.caption).fixedSize() }
    private var layoutControls: some View {
        HStack {
            Button { descending.toggle() } label: {
                Image(systemName: descending ? "arrow.up" : "arrow.down")
            }.buttonStyle(.plain).accessibilityLabel("Reverse file order")
            Picker("File layout", selection: $tree) {
                Label("Path", systemImage: "list.bullet").tag(false)
                Label("Tree", systemImage: "list.bullet.indent").tag(true)
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        }
    }

    private func fileRow(_ row: FileHierarchy<CommitFile>.Row) -> some View {
        Button {
            if let file = row.file { viewDiff(file) }
            else if !expanded.insert(row.path).inserted { expanded.remove(row.path) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: row.file != nil ? "doc" : expanded.contains(row.path) ? "chevron.down" : "chevron.right")
                Text(tree ? String(row.path.split(separator: "/").last ?? "") : formatPath(row.path, original: row.file?.originalPath))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                let counts = Dictionary(grouping: row.files.filter { !$0.unchanged }, by: \.status)
                ForEach(counts.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { status in
                    Label(row.file == nil ? "\(counts[status]?.count ?? 0)" : status.rawValue, systemImage: status.icon)
                        .font(.caption2).foregroundStyle(statusColor(status))
                }
            }.padding(.leading, tree ? CGFloat(row.path.split(separator: "/").count - 1) * 10 : 0)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).font(.caption).help(row.path)
        .contextMenu {
            if let file = row.file { Button(file.unchanged ? "Open File" : "Open Diff") { viewDiff(file) } }
            FileLocationMenu(root: root, path: row.path)
            Button("Copy Commit SHA") { copyGitText(commit.id) }
        }
    }
}

private struct WidthDivider: NSViewRepresentable {
    let label: String
    let width: CGFloat
    let limits: ClosedRange<CGFloat>
    var growsLeft = false
    let resize: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> Handle { Handle() }

    func updateNSView(_ handle: Handle, context: Context) {
        handle.width = width
        handle.limits = limits
        handle.growsLeft = growsLeft
        handle.toolTip = label + " · Drag to resize"
        handle.setAccessibilityLabel(label)
        handle.setAccessibilityValue(NSNumber(value: Double(width)))
        handle.resize = resize
    }

    final class Handle: NSView {
        var width: CGFloat = 294
        var limits: ClosedRange<CGFloat> = 0...294
        var growsLeft = false
        var resize: ((CGFloat, Bool) -> Void)?
        private var startX: CGFloat = 0
        private var startWidth: CGFloat = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.splitter)
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            NSColor(WorkspaceColors.sidebar).setFill()
            bounds.fill()
            NSColor(WorkspaceColors.divider).setFill()
            NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
            NSColor.secondaryLabelColor.setFill()
            let grip = min(24, bounds.height * 0.5)
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1, y: bounds.midY - grip / 2, width: 2, height: grip),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            startWidth = width
        }

        override func mouseDragged(with event: NSEvent) { move(event, finished: false) }
        override func mouseUp(with event: NSEvent) { move(event, finished: true) }

        private func move(_ event: NSEvent, finished: Bool) {
            let delta = event.locationInWindow.x - startX
            resize?(min(limits.upperBound, max(limits.lowerBound, startWidth + (growsLeft ? -delta : delta))), finished)
        }

        override func accessibilityPerformIncrement() -> Bool { resize?(min(limits.upperBound, width + 32), true); return true }
        override func accessibilityPerformDecrement() -> Bool { resize?(max(limits.lowerBound, width - 32), true); return true }
    }
}

func statusColor(_ status: FileChange.Status) -> Color {
    switch status {
    case .added, .untracked: Color(red: 0.48, green: 0.83, blue: 0.65)
    case .deleted, .conflict: Color(red: 1, green: 0.55, blue: 0.59)
    case .modified, .typeChanged: Color(red: 0.98, green: 0.74, blue: 0.43)
    case .renamed, .copied, .changed: WorkspaceColors.accent
    }
}

private struct PaneHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(WorkspaceColors.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WorkspaceColors.divider)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }
}

func formatPath(_ path: String, original: String?) -> String {
    func escaped(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
    let destination = escaped(path)
    return original.map { "\(escaped($0)) → \(destination)" } ?? destination
}
private struct CommitSearch: View {
    let root: URL
    let select: (GitCommit) -> Void
    @State private var query = ""
    @State private var results: [GitCommit] = []
    @State private var status = ""
    @State private var searchError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search commit messages on all branches", text: $query)
                .textFieldStyle(.roundedBorder)
            if let searchError { GitErrorDetails(title: "Search failed", message: searchError) }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            if !results.isEmpty {
                WorkspaceScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(results) { commit in
                            Button { select(commit) } label: {
                                HStack {
                                    Text(commit.shortID).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(commit.subject).lineLimit(1)
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).help(commit.subject)
                        }
                    }
                }.frame(maxHeight: 250)
            }
        }.padding(12).frame(width: 360)
        .task(id: query) {
            searchError = nil
            results = []
            status = ""
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(160))
                let found = try await GitHistory.commits(in: root, maximum: 30, query: term)
                try Task.checkCancellation()
                results = found
                if found.isEmpty { status = "No matching commits" }
            } catch { if !Task.isCancelled { searchError = error.localizedDescription } }
        }
    }
}

private struct BranchBadges<Badge: View, Actions: View>: View {
    let groups: [GraphReferenceBadge]
    let snapshot: RepositorySnapshot
    @ViewBuilder let badge: (GraphReferenceBadge) -> Badge
    @ViewBuilder let actions: (RepositoryReference) -> Actions
    @State private var pinnedID: String?

    var body: some View {
        GeometryReader { geo in
            let ordered = pinnedID.flatMap { id in groups.first { $0.id == id } }.map { pinned in
                [pinned] + groups.filter { $0.id != pinned.id }
            } ?? groups
            let widths = ordered.map { $0.width(checkedOut: snapshot.isCheckedOut($0.reference)) }
            let count = visibleCount(widths, available: geo.size.width)
            let hidden = ordered.dropFirst(count)
            HStack(spacing: 3) {
                ForEach(ordered.prefix(count)) { group in
                    badge(group)
                }
                if !hidden.isEmpty {
                    Menu {
                        ForEach(hidden) { group in
                            Menu(group.name) {
                                Button("Show Label in Graph") { pinnedID = group.id }
                                Divider()
                                if group.references.count == 1 {
                                    actions(group.reference)
                                } else {
                                    ForEach(group.references) { ref in
                                        Menu(ref.locationLabel + " · " + ref.name) { actions(ref) }
                                    }
                                }
                            }
                        }
                    } label: { Text("+\(hidden.count)").font(.system(size: 10, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize().layoutPriority(1)
                    .accessibilityLabel("Show \(hidden.count) more labels")
                    .help("Show other branches and tags at this commit")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func visibleCount(_ widths: [CGFloat], available: CGFloat) -> Int {
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            used += width + (index == 0 ? 0 : 3)
            let remaining = widths.count - index - 1
            let menuWidth = remaining == 0 ? 0 : CGFloat(16 + String(remaining).count * 7)
            if used + menuWidth > available { return max(1, index) }
        }
        return widths.count
    }
}

private struct SelectorStyle: ViewModifier {
    let caption: String
    let value: String

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            content.menuStyle(.borderlessButton).font(.callout.weight(.semibold))
                .frame(maxWidth: 150, alignment: .leading)
        }.accessibilityLabel(caption + ", " + value)
    }
}

private struct BranchDeletePrompt: View {
    let choice: BranchDeletion
    let confirm: (BranchDeletion, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reviewed: BranchDeletion?
    @State private var allowUnmerged = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(choice.title + "?").font(.title3.bold())
            if let tree = choice.worktree {
                Label(tree.id.path, systemImage: "externaldrive").textSelection(.enabled)
                Text("Git will remove this worktree folder and its contents.").foregroundStyle(.secondary)
            }
            if let branch = choice.local {
                Label(branch.name + " · " + branch.commitID.prefix(10), systemImage: branch.kind.icon)
                Toggle("Allow deletion if the local branch has unmerged commits", isOn: $allowUnmerged)
                    .toggleStyle(.checkbox)
            }
            if let remote = reviewed?.remote, let ref = choice.remoteRef {
                Label(remote.remote + " / " + remote.name + " · " + ref.commitID.prefix(10), systemImage: "network")
                Text("This deletes the branch on the remote for everyone using it.").foregroundStyle(.secondary)
            }
            if let error { GitErrorDetails(title: "Couldn’t review branch deletion", message: error) }
            else if reviewed == nil { ProgressView().controlSize(.small) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    guard let reviewed else { return }
                    dismiss()
                    confirm(reviewed, allowUnmerged)
                }.disabled(reviewed == nil)
            }
        }.padding(22).frame(width: 460)
        .task(id: choice.id) {
            do { reviewed = try await choice.reviewed() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct StashInspector: View {
    let stash: GitStash
    let root: URL
    let open: (DiffRequest.Source, CommitFile) -> Void

    private struct Section: Identifiable {
        let part: StashPart
        let files: [CommitFile]
        var id: StashPart.Kind { part.kind }
    }
    @State private var sections: [Section]?
    @State private var error: String?

    var body: some View {
        WorkspaceScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label(stash.selector, systemImage: "tray.full").font(.headline)
                Text(stash.subject).font(.callout).textSelection(.enabled)
                Text(String(stash.id.prefix(10))).font(.caption.monospaced()).foregroundStyle(.secondary)
                Divider()
                if let sections {
                    if sections.isEmpty { Text("This stash contains no file changes.").foregroundStyle(.secondary) }
                    ForEach(sections) { section in
                        Text("\(section.part.kind.rawValue) files (\(section.files.count))").font(.caption.weight(.semibold))
                        ForEach(section.files) { file in
                            let path = formatPath(file.path, original: file.originalPath)
                            Button { open(.stash(section.part), file) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: file.status.icon).foregroundStyle(statusColor(file.status))
                                    Text(path).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 2)
                                }.frame(minHeight: 22).contentShape(Rectangle())
                            }.buttonStyle(.plain).font(.caption).help(path)
                            .contextMenu {
                                Button("Open Diff") { open(.stash(section.part), file) }
                                FileLocationMenu(root: root, path: file.path)
                            }
                        }
                    }
                } else if let error { GitErrorDetails(title: "Couldn’t read stash", message: error) }
                else { ProgressView().controlSize(.small) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: stash.id) {
            do {
                var result: [Section] = []
                for part in stash.parts {
                    let files = try await GitHistory.files(in: root, comparing: part.trees)
                    try Task.checkCancellation()
                    if !files.isEmpty { result.append(Section(part: part, files: files)) }
                }
                sections = result
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
