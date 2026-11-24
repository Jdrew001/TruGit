import AppKit
import Observation

struct RepositorySnapshot: Identifiable, Sendable {
    let id = UUID()
    var worktreeRevision = UUID()
    let repository: GitRepository
    let commonDirectory: URL
    let references: [RepositoryReference]
    let referenceBadges: [GraphReferenceBadge]
    let sidebarReferences: [RepositoryReference.Kind: [GraphReferenceBadge]]
    let operationTitle: String?
    let worktrees: [GitWorktree]
    let remotes: [String]
    let stashes: [GitStash]
    let colors: BranchColors

    func isCheckedOut(_ reference: RepositoryReference) -> Bool {
        reference.kind == .local && reference.name == repository.branch
    }

    var checkedOutBranch: RepositoryReference? { references.first(where: isCheckedOut) }

    func checkoutBranch(for ref: RepositoryReference) -> RepositoryReference? {
        if ref.kind == .local { return ref }
        guard ref.kind == .remote else { return nil }
        let tracking = references.filter { $0.kind == .local && $0.upstreamID == ref.id }
        let name = ref.remoteTarget?.name
        return tracking.first { $0.name == name } ?? tracking.first(where: isCheckedOut) ?? tracking.first
            ?? references.first { $0.kind == .local && $0.name == name && $0.upstreamID == nil }
    }

    func checkoutTitle(for branch: RepositoryReference) -> String {
        if otherWorktree(for: branch.name) != nil { return "Switch to “" + branch.name + "” worktree" }
        return "Switch to " + branch.name
    }

    func switchTitle(for reference: RepositoryReference) -> String? {
        if let local = checkoutBranch(for: reference) { return checkoutTitle(for: local) }
        return reference.kind == .remote ? "Switch to " + reference.name : nil
    }

    func newLocalName(for remote: RepositoryReference) -> String {
        let preferred = remote.remoteTarget?.name ?? String(remote.name.split(separator: "/", maxSplits: 1).last ?? "")
        let locals = references.filter { $0.kind == .local }
        func available(_ name: String) -> Bool {
            !locals.contains { $0.name == name || $0.name.hasPrefix(name + "/") || name.hasPrefix($0.name + "/") }
        }
        if available(preferred) { return preferred }
        // Keep a branch tracking another remote intact when both remotes use the same name.
        let base = remote.name.replacingOccurrences(of: "/", with: "-")
        var candidate = base
        var suffix = 2
        while !available(candidate) {
            candidate = base + "-" + String(suffix)
            suffix += 1
        }
        return candidate
    }

    func remoteBranch(for local: RepositoryReference) -> RepositoryReference? {
        guard local.kind == .local else { return nil }
        if let upstream = local.upstreamID { return references.first { $0.id == upstream && $0.kind == .remote } }
        let matches = references.filter { $0.kind == .remote && $0.remoteTarget?.name == local.name }
        return matches.count == 1 ? matches[0] : nil
    }

    func canMergeBranches(from source: RepositoryReference? = nil) -> Bool {
        guard let destination = references.first(where: { $0.kind == .local && $0.id != source?.id }) else { return false }
        if let source { return source.kind != .tag }
        return references.contains { $0.kind != .tag && $0.id != destination.id }
    }

    func otherWorktree(for branch: String) -> GitWorktree? {
        GitWorktree.otherCheckout(of: branch, in: worktrees, outside: repository.root)
    }

    init(repository: GitRepository, commonDirectory: URL, references: [RepositoryReference], operationTitle: String?, worktrees: [GitWorktree] = [], stashes: [GitStash] = [], remotes: [String] = []) {
        self.commonDirectory = commonDirectory
        self.worktrees = worktrees
        self.remotes = remotes
        self.stashes = stashes
        self.repository = repository
        self.references = references
        referenceBadges = GraphReferenceBadge.grouped(references, currentBranch: repository.branch, remoteNames: remotes)
        let localAndTags = referenceBadges.filter { $0.reference.kind != .remote }
        let remoteBranches = references.filter { $0.kind == .remote }.map { reference in
            let name = reference.remoteTarget.map { $0.remote + "/" + $0.name } ?? reference.name
            return GraphReferenceBadge(name: name, reference: reference, remotes: [])
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        sidebarReferences = Dictionary(grouping: localAndTags + remoteBranches, by: \.reference.kind)
        self.operationTitle = operationTitle
        colors = BranchColors(references: references, currentBranch: repository.branch)
    }
}

enum RepositoryFetchStatus {
    case fetching
    case fetched(Date)
    case unavailable(Date)

    private static let retryInterval: TimeInterval = 5 * 60

    var isDue: Bool {
        switch self {
        case .fetching: false
        case .fetched(let date), .unavailable(let date): Date.now.timeIntervalSince(date) >= Self.retryInterval
        }
    }
}

@MainActor
@Observable
final class RepositoryModel {
    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        var retry: RemoteRetry? = nil
    }

    struct RemoteRetry {
        let root: URL
        let branch: RepositoryReference
        let isPush: Bool
        var exactPush: GitBranchAction?

        init?(_ action: GitBranchAction, in root: URL, pinPush: Bool = false) {
            self.root = root
            switch action {
            case .revision(let request) where request.operation.pushes || request.operation == .publish:
                guard let ref = request.source.reference else { return nil }
                branch = ref
                isPush = true
                exactPush = action
            case .publish(let ref, _, _): branch = ref; isPush = true; exactPush = action
            case .pull(let ref): branch = ref; isPush = false
            case .push(let ref): branch = ref; isPush = true; exactPush = pinPush ? action : nil
            default: return nil
            }
        }
    }

    private(set) var retryingFailureID: UUID?


    private(set) var tabs: [RepositoryTab] = []
    private(set) var activeID: URL?
    private(set) var isLoading = false
    private var automaticFetches: [URL: RepositoryFetchStatus] = [:]
    struct Success: Identifiable {
        let id = UUID()
        let message: String
    }

    var success: Success?
    var failure: Failure?
    struct InitializationReview: Identifiable {
        let id = UUID()
        let folders: [GitRepository.Initialization]
        let openErrors: [String]
    }

    var initialization: InitializationReview?
    var showingClone = false
    private var session = RepositorySession()
    private enum LaunchPhase { case pending, restoring, ready }
    private var launchPhase = LaunchPhase.pending
    var isLaunching: Bool { launchPhase != .ready }

    func restoreSession(minimumDisplayTime: Duration) {
        guard launchPhase == .pending else { return }
        launchPhase = .restoring
        isLoading = true
        Task {
            let earliestReveal = ContinuousClock.now + minimumDisplayTime
            await restoreRepositoryTabs()
            try? await Task.sleep(until: earliestReveal, clock: .continuous)
            isLoading = false
            launchPhase = .ready
        }
    }

    private func restoreRepositoryTabs() async {
        var restored: [RepositoryTab] = []
        var seen = Set<String>()
        var errors: [String] = []
        let selectedPath = session.selectedPath
        for path in session.paths where path.hasPrefix("/") && seen.insert(path).inserted {
            do {
                let snapshot = try await restoreSnapshot(for: path)
                if let existing = restored.first(where: { $0.snapshot.commonDirectory == snapshot.commonDirectory }) {
                    if path == selectedPath {
                        existing.activateWorktree(snapshot)
                        session.selectedPath = existing.id.path
                    }
                    if existing.alias == nil, let alias = session.aliases[path] {
                        existing.alias = alias
                        session.aliases[existing.id.path] = alias
                    }
                    session.removeTab(path)
                    recordWorktree(for: existing)
                } else {
                    let tab = RepositoryTab(snapshot: snapshot, id: URL(fileURLWithPath: path, isDirectory: true),
                                            alias: session.aliases[path])
                    restored.append(tab)
                    recordWorktree(for: tab)
                }
            } catch {
                errors.append(path + "\n" + error.localizedDescription)
            }
        }
        reportFolderErrors(errors, title: "Couldn’t Reopen Saved Repositories")
        tabs = restored
        activeID = restored.first { $0.id.path == session.selectedPath }?.id ?? restored.first?.id
        session.selectedPath = activeID?.path
        session.save()
    }

    private func restoreSnapshot(for path: String) async throws -> RepositorySnapshot {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        if let saved = session.worktreePaths[path], saved.hasPrefix("/"), saved != path {
            let worktree = URL(fileURLWithPath: saved, isDirectory: true).resolvingSymlinksInPath()
            if let snapshot = try? await Self.readSnapshot(at: worktree),
               snapshot.repository.root == worktree {
                let anchor = folder.resolvingSymlinksInPath()
                if session.commonDirectories[path] == snapshot.commonDirectory.path || snapshot.worktrees.contains(where: { $0.id == anchor }) {
                    return snapshot
                }
            }
        }
        let snapshot = try await Self.readSnapshot(at: folder)
        guard snapshot.repository.root == folder.resolvingSymlinksInPath() else {
            throw RepositoryReadError.commandFailed("The saved checkout no longer points to its repository.")
        }
        return snapshot
    }

    func setAlias(_ name: String, for tab: RepositoryTab) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.alias = trimmed.isEmpty ? nil : trimmed
        session.aliases[tab.id.path] = tab.alias
        session.save()
    }

    var tabGroups: [RepositoryTabGroup] { session.groups }

    func organizeTabs(_ change: TabOrganizationChange) {
        session.apply(change)
        let open = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id.path, $0) })
        tabs = session.paths.compactMap { open[$0] }
        session.save()
    }

    var activeTab: RepositoryTab? {
        tabs.first { $0.id == activeID }
    }

    var activeFetchStatus: RepositoryFetchStatus? {
        guard let snapshot = activeTab?.snapshot, !snapshot.remotes.isEmpty else { return nil }
        return automaticFetches[snapshot.commonDirectory]
    }

    func fetchActiveRepositoryInBackground() {
        guard !isLoading, let tab = activeTab, !tab.snapshot.remotes.isEmpty else { return }
        let group = tab.snapshot.commonDirectory
        let root = tab.root
        guard automaticFetches[group]?.isDue ?? true else { return }
        automaticFetches[group] = .fetching
        Task(priority: .utility) {
            do {
                try await GitRepository.fetchInBackground(in: root)
                automaticFetches[group] = .fetched(.now)
            } catch {
                automaticFetches[group] = .unavailable(.now)
            }
        }
    }

    enum FolderAction {
        case add, initialize
    }

    func openRepository() { chooseFolder(for: .add) }

    func showCloneSheet() {
        guard !isLoading, initialization == nil else { return }
        showingClone = true
    }

    func cloneRepository(_ request: RepositoryClone) async throws {
        guard !isLoading else { throw RepositoryReadError.commandFailed("Wait for the current Git operation to finish.") }
        isLoading = true
        defer { isLoading = false }
        success = nil
        let destination = try await request.run()
        do {
            showRepository(try await Self.readSnapshot(at: destination))
            success = Success(message: "Cloned " + destination.lastPathComponent)
        } catch {
            throw RepositoryReadError.commandFailed("Cloned to " + destination.path + " but couldn’t open the repository. " + error.localizedDescription)
        }
    }

    func chooseFolder(for action: FolderAction) {
        guard !isLoading, initialization == nil, !showingClone else { return }
        let panel = NSOpenPanel()
        panel.title = action == .add ? "Add Repositories" : "Initialize Repositories"
        panel.prompt = "Choose"
        panel.message = "Select one or more folders."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = activeTab?.root.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return }
        addFolders(panel.urls, action: action)
    }

    func addFolders(_ urls: [URL], action: FolderAction) {
        guard !isLoading, initialization == nil, !urls.isEmpty else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            var seenFolders = Set<URL>()
            var seenRoots = Set<URL>()
            var pending: [GitRepository.Initialization] = []
            var opened: [RepositorySnapshot] = []
            var errors: [String] = []
            for url in urls {
                let folder = URL(fileURLWithPath: url.path, isDirectory: true).resolvingSymlinksInPath()
                guard seenFolders.insert(folder).inserted else { continue }
                do {
                    let root = try await GitRepository.enclosingRoot(of: folder)
                    if let root, action == .add || root == folder {
                        if seenRoots.insert(root).inserted { opened.append(try await Self.readSnapshot(at: root)) }
                    } else {
                        pending.append(.init(folder: folder, enclosingRepository: root))
                    }
                } catch {
                    errors.append(folder.path + "\n" + error.localizedDescription)
                }
            }
            openRepositoryTabs(opened)
            if pending.isEmpty {
                reportFolderErrors(errors, title: "Couldn’t Open Selected Folders")
            } else {
                initialization = InitializationReview(folders: pending, openErrors: errors)
            }
        }
    }

    func initializeRepositories(_ review: InitializationReview, selected: Set<URL>) {
        guard !isLoading, initialization?.id == review.id else { return }
        initialization = nil
        let requests = review.folders.filter { selected.contains($0.folder) }
        guard !requests.isEmpty else { return }
        success = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            var opened: [RepositorySnapshot] = []
            var errors: [String] = []
            for request in requests {
                do {
                    try await request.run()
                    opened.append(try await Self.readSnapshot(at: request.folder))
                } catch {
                    errors.append(request.folder.path + "\n" + error.localizedDescription)
                }
            }
            openRepositoryTabs(opened)
            if let first = opened.first {
                success = Success(message: opened.count == 1 ? "Initialized " + first.repository.root.lastPathComponent
                                  : "Initialized \(opened.count) repositories")
            }
            reportFolderErrors(errors, title: "Couldn’t Initialize Selected Folders")
        }
    }

    private func openRepositoryTabs(_ snapshots: [RepositorySnapshot]) {
        // Select once so adding a batch leaves the other groups' disclosure state intact.
        let opened = snapshots.map { tab(for: $0) }
        if let last = opened.last { selectTab(last.id) }
    }

    private func reportFolderErrors(_ errors: [String], title: String) {
        guard !errors.isEmpty else { return }
        failure = Failure(title: title, message: errors.joined(separator: "\n\n"))
    }

    func switchWorktree(to root: URL, in tab: RepositoryTab) {
        perform(failureTitle: "Couldn’t Switch Worktrees") {
            try await self.readWorktree(at: root, from: tab.snapshot)
        } onLoad: { snapshot in
            let changed = tab.root != snapshot.repository.root
            self.activateWorktree(snapshot, in: tab)
            if changed { self.success = Success(message: "Switched to worktree for " + snapshot.repository.branch) }
            tab.selection = .history
            tab.diff = nil
            tab.worktreeFileCommit = nil
            if !snapshot.repository.changes.isEmpty || snapshot.repository.integration != nil {
                tab.showWorkInProgress()
            } else if let head = snapshot.repository.headID {
                tab.worktreeFileCommit = head
                tab.commitJump = CommitJump(commitID: head)
                tab.historySelection = .commit(head)
            }
        }
    }

    private func showRepository(_ snapshot: RepositorySnapshot) {
        selectTab(tab(for: snapshot).id)
    }

    private func tab(for snapshot: RepositorySnapshot) -> RepositoryTab {
        if let existing = tabs.first(where: { $0.snapshot.commonDirectory == snapshot.commonDirectory }) {
            activateWorktree(snapshot, in: existing)
            return existing
        }
        let root = snapshot.worktrees.first(where: \.isMain)?.id ?? snapshot.repository.root
        let tab = RepositoryTab(snapshot: snapshot, id: root, alias: session.aliases[root.path])
        tabs.append(tab)
        if !session.paths.contains(root.path) { session.paths.append(root.path) }
        recordWorktree(for: tab)
        return tab
    }

    private func activateWorktree(_ snapshot: RepositorySnapshot, in tab: RepositoryTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        tab.activateWorktree(snapshot)
        recordWorktree(for: tab)
        session.save()
    }

    private func recordWorktree(for tab: RepositoryTab) {
        session.worktreePaths[tab.id.path] = tab.root.path
        session.commonDirectories[tab.id.path] = tab.snapshot.commonDirectory.path
    }

    func selectTab(_ root: URL) {
        guard tabs.contains(where: { $0.id == root }) else { return }
        activeID = root
        session.revealTab(root.path)
        session.selectedPath = root.path
        session.save()
    }

    func closeActiveTab() {
        if let activeID { closeTab(activeID) }
    }

    func closeTab(_ root: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == root }) else { return }
        if let retry = failure?.retry, retryTab(in: retry.root)?.id == root { failure = nil }
        tabs.remove(at: index)
        session.removeTab(root.path)
        if activeID == root {
            activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            session.selectedPath = activeID?.path
        }
        session.save()
    }

    func refresh() {
        guard let tab = activeTab else { return }
        guard !isLoading else { return }
        success = nil
        load(tab.root) { snapshot in
            tab.snapshot = snapshot
            self.success = Success(message: "Refreshed " + tab.title)
        }
    }

    func observeActiveRepository() async {
        guard let tab = activeTab else { return }
        let root = tab.root
        let dirs = try? await GitRepository.git(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: root)
        let metadata = dirs.map { String(decoding: $0, as: UTF8.self).split(separator: "\n").map(String.init) } ?? []
        let paths = Set([root.path] + metadata.filter { !$0.hasPrefix(root.path + "/") })
        guard !Task.isCancelled, let events = RepositoryEvents(paths: Array(paths)) else { return }
        defer { events.stop() }
        var lastError: String?
        for await _ in events.updates {
            guard !Task.isCancelled else { break }
            guard !isLoading, tab.root == root else { continue }
            let original = tab.snapshot
            var latest: RepositorySnapshot
            do {
                latest = try await Self.readSnapshot(at: root)
            } catch {
                guard !Task.isCancelled, !isLoading, activeID == tab.id, tab.root == root else { continue }
                let message = error.localizedDescription
                if message != lastError, failure == nil {
                    failure = Failure(title: "Couldn’t Refresh " + tab.title, message: message)
                    lastError = message
                }
                continue
            }
            lastError = nil
            guard !Task.isCancelled, !isLoading, tab.snapshot.id == original.id else { continue }
            if latest.repository != original.repository || latest.references != original.references ||
                latest.operationTitle != original.operationTitle || latest.worktrees != original.worktrees || latest.stashes != original.stashes || latest.remotes != original.remotes {
                if latest.repository == original.repository && latest.operationTitle == original.operationTitle {
                    latest.worktreeRevision = original.worktreeRevision
                }
                tab.snapshot = latest
            }
        }
    }

    func canRetry(in root: URL) -> Bool { retryTab(in: root) != nil }

    private func retryTab(in root: URL) -> RepositoryTab? {
        tabs.first { tab in tab.root == root || tab.snapshot.worktrees.contains { $0.id == root && !$0.isPrunable } }
    }

    func retryFailure(_ id: UUID) {
        guard !isLoading, let failure, failure.id == id, let retry = failure.retry,
              let tab = retryTab(in: retry.root) else { return }
        // Use the latest tip on the original branch. The normal action rechecks
        // HEAD and upstream against Git before it contacts the remote.
        let latest = tab.snapshot.references.first { $0.id == retry.branch.id && $0.upstreamID == retry.branch.upstreamID }
        let branch = latest ?? retry.branch
        selectTab(tab.id)
        let action = retry.exactPush ?? (retry.isPush ? .push(branch) : .pull(branch))
        performBranchAction(action, in: tab, retrying: id, retryRoot: retry.root)
    }

    func performBranchAction(_ action: GitBranchAction, in tab: RepositoryTab, retrying failureID: UUID? = nil, retryRoot: URL? = nil) {
        guard !isLoading else { return }
        isLoading = true

        success = nil
        retryingFailureID = failureID
        Task {
            defer {
                retryingFailureID = nil
                isLoading = false
            }
            do {
                if let retryRoot, retryRoot != tab.root {
                    let original = try await readWorktree(at: retryRoot, from: tab.snapshot)
                    activateWorktree(original, in: tab)
                }
                if let owner = try await destinationWorktree(for: action, from: tab) {
                    activateWorktree(owner, in: tab)
                    let checkoutOnly: Bool
                    switch action {
                    case .switchTo: checkoutOnly = true
                    case .revision(let request): checkoutOnly = request.operation == .checkout
                    default: checkoutOnly = false
                    }
                    if checkoutOnly {
                        success = Success(message: "Switched to worktree for " + owner.repository.branch)
                        if owner.repository.integration != nil || !owner.repository.changes.isEmpty {
                            tab.showWorkInProgress()
                        } else if tab.pendingCommitBatch == nil, let branch = owner.checkedOutBranch {
                            tab.selectReference(branch)
                        }
                        return
                    }
                }
            } catch {
                failure = Failure(title: action.failureTitle, message: error.localizedDescription)
                return
            }
            let before = tab.snapshot.repository
            let root = before.root
            tab.pushingTo = action.pushDestination
            let actionError = await runBranchAction(action, in: root)
            if actionError == nil { success = Success(message: action.successMessage) }
            tab.pushingTo = nil
            let pushFailure = actionError as? CommitPushFailure
            let failureTitle = pushFailure == nil ? action.failureTitle : "Committed locally · Push failed"
            let retry = pushFailure?.push.flatMap { RemoteRetry($0, in: root, pinPush: true) }
                ?? (failureID != nil && failure?.id == failureID ? failure?.retry : nil)
                ?? RemoteRetry(action, in: root)
            if actionError == nil || pushFailure != nil, case .worktree(let work) = action {
                tab.diff = nil
                if case .commit = work { tab.commitDraft = CommitDraft() }
            }
            if case .deleteBranch(let deletion, _) = action, let tree = deletion.worktree {
                do {
                    let refreshed = try await Self.readSnapshot(at: deletion.commandRoot)
                    if reconcileRemovedWorktree(tree, in: tab, with: refreshed) {
                        if let actionError { failure = Failure(title: action.failureTitle, message: actionError.localizedDescription) }
                        return
                    }
                } catch {
                    failure = Failure(title: action.failureTitle, message: (actionError ?? error).localizedDescription)
                    return
                }
            }
            do {
                let snapshot = try await Self.readSnapshot(at: root)
                tab.snapshot = snapshot
                if actionError == nil {
                    if case .switchTo = action, before.branch != snapshot.repository.branch,
                       let head = snapshot.repository.headID, before.headID != nil,
                       snapshot.references.contains(where: { $0.kind == .local && $0.name == before.branch }) {
                        tab.switchUndo = SwitchStep(from: snapshot.repository.branch, head: head, to: before.branch)
                        tab.switchRedo = nil
                    } else if case .replaySwitch(let from, _, let to) = action, let head = snapshot.repository.headID {
                        let reverse = SwitchStep(from: to, head: head, to: from)
                        if tab.switchUndo?.from == from { tab.switchUndo = nil; tab.switchRedo = reverse }
                        else { tab.switchRedo = nil; tab.switchUndo = reverse }
                    } else {
                        tab.switchUndo = nil
                        tab.switchRedo = nil
                    }
                }
                if snapshot.repository.integration != nil {
                    if actionError == nil || action.canPauseForConflicts { tab.diff = nil }
                    tab.showWorkInProgress()
                } else if case .stashEntry(let operation, _) = action, operation != .delete,
                          !snapshot.repository.changes.isEmpty, actionError == nil || snapshot.repository.changes.contains(where: { $0.staged == .conflict }) {
                    tab.diff = nil
                    tab.showWorkInProgress()
                } else if actionError == nil && action.returnsToHistory {
                    tab.diff = nil
                    tab.selection = .history
                    if let head = snapshot.repository.headID {
                        tab.commitJump = CommitJump(commitID: head)
                    }
                }
            } catch {
                if let actionError {
                    failure = Failure(title: failureTitle, message: actionError.localizedDescription + "\n\nRefresh also failed.\n" + error.localizedDescription,
                                      retry: retry)
                } else {
                    failure = Failure(title: "Couldn’t Refresh Repository", message: error.localizedDescription)
                }
                return
            }
            if let actionError {
                failure = Failure(title: failureTitle, message: actionError.localizedDescription,
                                  retry: retry)
            } else if let failureID, failure?.id == failureID {
                failure = nil
            }
        }
    }

    private func reconcileRemovedWorktree(_ tree: GitWorktree, in tab: RepositoryTab, with snapshot: RepositorySnapshot) -> Bool {
        guard !snapshot.worktrees.contains(where: { $0.id == tree.id }) else { return false }
        activateWorktree(snapshot, in: tab)
        tab.forgetWorktree(tree.id)
        return true
    }

    private func destinationWorktree(for action: GitBranchAction, from tab: RepositoryTab) async throws -> RepositorySnapshot? {
        let branch: String
        var revision: RevisionAction?
        switch action {
        case .switchTo(let name): branch = name
        case .revision(let request):
            guard let point = request.operation.checkoutBranch(source: request.source, target: request.target), point.isLocal else { return nil }
            branch = point.name
            revision = request
        default: return nil
        }

        let worktrees = try await GitHistory.worktrees(in: tab.root)
        let owner = GitWorktree.otherCheckout(of: branch, in: worktrees, outside: tab.root)
        if let revision, revision.operation != .checkout, revision.reviewedWorktree != owner?.id {
            throw RepositoryReadError.commandFailed("The worktree for “" + branch + "” changed. Review the destination again.")
        }
        guard let owner else { return nil }
        let snapshot = try await readWorktree(owner, from: tab.snapshot)
        guard snapshot.repository.branch == branch else {
            throw RepositoryReadError.commandFailed("The branch in " + owner.id.path + " changed. Refresh and try again.")
        }
        if let revision, revision.operation == .checkout { try await revision.source.validate(in: owner.id) }
        return snapshot
    }

    private func readWorktree(at root: URL, from source: RepositorySnapshot) async throws -> RepositorySnapshot {
        let worktrees = try await GitHistory.registeredWorktrees(in: source.commonDirectory)
        guard let worktree = worktrees.first(where: { $0.id == root }) else {
            throw RepositoryReadError.commandFailed("Git no longer lists a worktree at " + root.path + ". Refresh and try again.")
        }
        return try await readWorktree(worktree, from: source)
    }

    private func readWorktree(_ worktree: GitWorktree, from source: RepositorySnapshot) async throws -> RepositorySnapshot {
        let root = worktree.id
        guard !worktree.isPrunable else {
            throw RepositoryReadError.commandFailed("Git lists an unavailable worktree at " + root.path + ". Repair or remove its Git worktree registration, then refresh.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RepositoryReadError.commandFailed("The registered worktree folder is missing at " + root.path + ".")
        }
        let snapshot = try await Self.readSnapshot(at: root)
        guard snapshot.repository.root == root, snapshot.commonDirectory == source.commonDirectory,
              snapshot.worktrees.contains(where: { $0.id == root && !$0.isPrunable }) else {
            throw RepositoryReadError.commandFailed("The folder at " + root.path + " no longer matches this repository’s worktree registration.")
        }
        return snapshot
    }

    private func runBranchAction(_ action: GitBranchAction, in root: URL) async -> (any Error)? {
        do {
            try await action.run(in: root)
            return nil
        } catch {
            return error
        }
    }

    private func load(_ folder: URL, onLoad: @escaping (RepositorySnapshot) -> Void) {
        perform(failureTitle: "Couldn’t Read Repository") {
            try await Self.readSnapshot(at: folder)
        } onLoad: { onLoad($0) }
    }

    private func perform(failureTitle: String, operation: @escaping () async throws -> RepositorySnapshot,
                         onLoad: @escaping (RepositorySnapshot) -> Void) {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                onLoad(try await operation())
            } catch {
                failure = Failure(title: failureTitle, message: error.localizedDescription)
            }
        }
    }

    private static func readSnapshot(at folder: URL) async throws -> RepositorySnapshot {
        let repository = try await GitRepository.read(at: folder)
        let references = try await GitHistory.references(in: repository.root)
        var title: String?
        if repository.integration == .merge {
            let path = try await GitRepository.git(["rev-parse", "--path-format=absolute", "--git-path", "MERGE_MSG"], in: repository.root)
            let message = try? String(contentsOfFile: String(decoding: path.dropLast(), as: UTF8.self), encoding: .utf8)
            let subject = message?.components(separatedBy: .newlines).first ?? ""
            title = subject.hasPrefix("Merge ") && subject.contains(" into ") ? subject : "Merge into \(repository.branch)"
        }
        async let commonDirectory = GitRepository.commonDirectory(in: repository.root)
        async let remotes = GitRepository.git(["remote"], in: repository.root)
        async let worktrees = GitHistory.worktrees(in: repository.root)
        async let stashes = GitHistory.stashes(in: repository.root)
        return try await RepositorySnapshot(repository: repository, commonDirectory: commonDirectory, references: references, operationTitle: title,
                                            worktrees: worktrees, stashes: stashes,
                                            remotes: String(decoding: remotes, as: UTF8.self).split(separator: "\n").map(String.init))
    }

}
