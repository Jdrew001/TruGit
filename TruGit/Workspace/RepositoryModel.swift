import AppKit
import Observation

struct RepositorySnapshot: Identifiable, Sendable {
    let id = UUID()
    let repository: GitRepository
    let references: [RepositoryReference]
    let operationTitle: String?
    let worktrees: [GitWorktree]
    let remotes: [String]
    let stashes: [GitStash]
    let colors: BranchColors

    func otherWorktree(for branch: String) -> GitWorktree? {
        GitWorktree.otherCheckout(of: branch, in: worktrees, outside: repository.root)
    }

    init(repository: GitRepository, references: [RepositoryReference], operationTitle: String?, worktrees: [GitWorktree] = [], stashes: [GitStash] = [], remotes: [String] = []) {
        self.worktrees = worktrees
        self.remotes = remotes
        self.stashes = stashes
        self.repository = repository
        self.references = references
        self.operationTitle = operationTitle
        colors = BranchColors(references: references, currentBranch: repository.branch)
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
        for path in session.paths where path.hasPrefix("/") && seen.insert(path).inserted {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            do {
                let snapshot = try await Self.readSnapshot(at: folder)
                guard snapshot.repository.root.path == path else { continue }
                restored.append(RepositoryTab(snapshot: snapshot, alias: session.aliases[path]))
            } catch {
                errors.append(path + "\n" + error.localizedDescription)
            }
        }
        reportFolderErrors(errors, title: "Couldn’t Reopen Saved Repositories")
        tabs = restored
        activeID = restored.first { $0.id.path == session.selectedPath }?.id ?? restored.first?.id
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
        let destination = try await request.run()
        do {
            showRepository(try await Self.readSnapshot(at: destination))
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
        panel.directoryURL = activeTab?.id.deletingLastPathComponent()
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

    func openFolder(_ folder: URL, inspectWorktree: Bool = false) {
        load(folder) { self.showRepository($0, inspectWorktree: inspectWorktree) }
    }

    private func showRepository(_ snapshot: RepositorySnapshot, inspectWorktree: Bool = false) {
        let tab = tab(for: snapshot)
        if inspectWorktree {
            tab.diff = nil
            tab.selection = .history
            tab.worktreeFileCommit = nil
            if !snapshot.repository.changes.isEmpty || snapshot.repository.integration != nil {
                tab.showWorkInProgress()
            } else if let head = snapshot.repository.headID {
                tab.worktreeFileCommit = head
                tab.commitJump = CommitJump(commitID: head)
                tab.historySelection = .commit(head)
            }
        }
        selectTab(tab.id)
    }

    private func tab(for snapshot: RepositorySnapshot, preserveSavedPosition: Bool = false) -> RepositoryTab {
        let root = snapshot.repository.root
        if let existing = tabs.first(where: { $0.id == root }) {
            existing.snapshot = snapshot
            return existing
        }
        let tab = RepositoryTab(snapshot: snapshot, alias: session.aliases[root.path])
        if preserveSavedPosition, let index = session.paths.firstIndex(of: root.path) {
            let preceding = Set(session.paths.prefix(index))
            tabs.insert(tab, at: tabs.prefix { preceding.contains($0.id.path) }.count)
        } else {
            tabs.append(tab)
            session.removeTab(root.path)
            session.paths.append(root.path)
        }
        return tab
    }

    func selectTab(_ root: URL) {
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
        if failure?.retry?.root == root { failure = nil }
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
        load(tab.id) { snapshot in tab.snapshot = snapshot }
    }

    func observeActiveRepository() async {
        guard let tab = activeTab else { return }
        let dirs = try? await GitRepository.git(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: tab.id)
        let metadata = dirs.map { String(decoding: $0, as: UTF8.self).split(separator: "\n").map(String.init) } ?? []
        let paths = Set([tab.id.path] + metadata.filter { !$0.hasPrefix(tab.id.path + "/") })
        guard !Task.isCancelled, let events = RepositoryEvents(paths: Array(paths)) else { return }
        defer { events.stop() }
        var lastError: String?
        for await _ in events.updates {
            guard !Task.isCancelled else { break }
            guard !isLoading else { continue }
            let original = tab.snapshot
            let latest: RepositorySnapshot
            do {
                latest = try await Self.readSnapshot(at: tab.id)
            } catch {
                guard !Task.isCancelled, !isLoading, activeID == tab.id else { continue }
                let message = error.localizedDescription
                if message != lastError, failure == nil {
                    failure = Failure(title: "Couldn’t Refresh " + tab.id.lastPathComponent, message: message)
                    lastError = message
                }
                continue
            }
            lastError = nil
            guard !Task.isCancelled, !isLoading, tab.snapshot.id == original.id else { continue }
            if latest.repository != original.repository || latest.references != original.references ||
                latest.operationTitle != original.operationTitle || latest.worktrees != original.worktrees || latest.stashes != original.stashes || latest.remotes != original.remotes {
                tab.snapshot = latest
            }
        }
    }

    func retryFailure(_ id: UUID) {
        guard !isLoading, let failure, failure.id == id, let retry = failure.retry,
              let tab = tabs.first(where: { $0.id == retry.root }) else { return }
        // Use the latest tip on the original branch. The normal action rechecks
        // HEAD and upstream against Git before it contacts the remote.
        let latest = tab.snapshot.references.first { $0.id == retry.branch.id && $0.upstreamID == retry.branch.upstreamID }
        let branch = latest ?? retry.branch
        selectTab(tab.id)
        let action = retry.exactPush ?? (retry.isPush ? .push(branch) : .pull(branch))
        performBranchAction(action, in: tab, retrying: id)
    }

    func performBranchAction(_ action: GitBranchAction, in sourceTab: RepositoryTab, retrying failureID: UUID? = nil) {
        guard !isLoading else { return }
        isLoading = true

        retryingFailureID = failureID
        Task {
            defer {
                retryingFailureID = nil
                isLoading = false
            }
            let tab: RepositoryTab
            do {
                if let owner = try await destinationWorktree(for: action, from: sourceTab) {
                    tab = self.tab(for: owner)
                    selectTab(tab.id)
                    if case .switchTo = action { return }
                    if case .revision(let request) = action, request.operation == .checkout { return }
                } else {
                    tab = sourceTab
                }
            } catch {
                failure = Failure(title: action.failureTitle, message: error.localizedDescription)
                return
            }
            let before = tab.snapshot.repository
            let actionError = await runBranchAction(action, in: tab.id)
            let pushFailure = actionError as? CommitPushFailure
            let failureTitle = pushFailure == nil ? action.failureTitle : "Committed locally · Push failed"
            let retry = pushFailure?.push.flatMap { RemoteRetry($0, in: tab.id, pinPush: true) }
                ?? (failureID != nil && failure?.id == failureID ? failure?.retry : nil)
                ?? RemoteRetry(action, in: tab.id)
            if actionError == nil || pushFailure != nil, case .worktree(let work) = action {
                tab.diff = nil
                if case .commit = work { tab.commitDraft = CommitDraft() }
            }
            if case .deleteBranch(let deletion, _) = action, let tree = deletion.worktree {
                do {
                    let refreshed = try await Self.readSnapshot(at: deletion.commandRoot)
                    if reconcileRemovedWorktree(tree, with: refreshed) {
                        if let actionError { failure = Failure(title: action.failureTitle, message: actionError.localizedDescription) }
                        return
                    }
                } catch {
                    failure = Failure(title: action.failureTitle, message: (actionError ?? error).localizedDescription)
                    return
                }
            }
            do {
                let snapshot = try await Self.readSnapshot(at: tab.id)
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
                if tab.id != sourceTab.id {
                    sourceTab.snapshot = try await Self.readSnapshot(at: sourceTab.id)
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

    private func reconcileRemovedWorktree(_ tree: GitWorktree, with snapshot: RepositorySnapshot) -> Bool {
        guard !snapshot.worktrees.contains(where: { $0.id.path == tree.id.path }) else { return false }
        let wasActive = activeID?.path == tree.id.path
        if let removed = tabs.first(where: { $0.id.path == tree.id.path }) { closeTab(removed.id) }
        if wasActive {
            let surviving = tab(for: snapshot, preserveSavedPosition: true)
            selectTab(surviving.id)
        } else if let surviving = tabs.first(where: { $0.id == snapshot.repository.root }) {
            surviving.snapshot = snapshot
        }
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

        let worktrees = try await GitHistory.worktrees(in: tab.id)
        let owner = GitWorktree.otherCheckout(of: branch, in: worktrees, outside: tab.id)
        if let revision, revision.operation != .checkout, revision.reviewedWorktree != owner?.id {
            throw RepositoryReadError.commandFailed("The worktree for “" + branch + "” changed. Review the destination again.")
        }
        guard let owner else { return nil }
        guard FileManager.default.fileExists(atPath: owner.id.path) else {
            throw RepositoryReadError.commandFailed("Git lists “" + branch + "” at " + owner.id.path + ", but the worktree folder is missing.")
        }
        let snapshot = try await Self.readSnapshot(at: owner.id)
        guard snapshot.repository.root.resolvingSymlinksInPath() == owner.id.resolvingSymlinksInPath(),
              snapshot.repository.branch == branch,
              snapshot.worktrees.contains(where: { $0.id.resolvingSymlinksInPath() == tab.id.resolvingSymlinksInPath() }) else {
            throw RepositoryReadError.commandFailed("Git’s worktree registration for “" + branch + "” no longer matches " + owner.id.path + ". Refresh and try again.")
        }
        if let revision, revision.operation == .checkout { try await revision.source.validate(in: owner.id) }
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
        async let remotes = GitRepository.git(["remote"], in: repository.root)
        async let worktrees = GitHistory.worktrees(in: repository.root)
        async let stashes = GitHistory.stashes(in: repository.root)
        return try await RepositorySnapshot(repository: repository, references: references, operationTitle: title,
                                            worktrees: worktrees, stashes: stashes,
                                            remotes: String(decoding: remotes, as: UTF8.self).split(separator: "\n").map(String.init))
    }

}
