import Foundation

enum GitIntegration: String, Sendable {
    case merge, rebase, cherryPick = "cherry-pick", revert, squashPick = "squash cherry-pick"

    var gitCommand: String { self == .squashPick ? "rebase" : rawValue }

    var title: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .squashPick: "Squash Cherry-pick"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }

    static func read(in root: URL) async throws -> Self? {
        let output = try await GitRepository.git(["rev-parse", "--absolute-git-dir"], in: root)
        guard output.last == 0x0A else { throw RepositoryReadError.invalidOutput }
        let path = String(decoding: output.dropLast(), as: UTF8.self)
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: path + "/" + name)
        }

        if exists("rebase-merge") {
            let done = URL(fileURLWithPath: path).appendingPathComponent("rebase-merge/done")
            if let handle = try? FileHandle(forReadingFrom: done) {
                defer { try? handle.close() }
                let marker = Data(("label " + CommitBatchPlan.label + "\n").utf8)
                if try handle.read(upToCount: marker.count) == marker { return .squashPick }
            }
            return .rebase
        }
        if exists("rebase-apply/rebasing") { return .rebase }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        if exists("MERGE_HEAD") { return .merge }
        if exists("sequencer") {
            let file = URL(fileURLWithPath: path).appendingPathComponent("sequencer/todo")
            do {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                let todo = String(decoding: data, as: UTF8.self)
                let first = todo.split(whereSeparator: \.isNewline).first { !$0.hasPrefix("#") }
                if first?.hasPrefix("pick ") == true { return .cherryPick }
                if first?.hasPrefix("revert ") == true { return .revert }
            } catch CocoaError.fileReadNoSuchFile {
                // Git may finish the sequence while the repository is refreshing.
            }
        }
        return nil
    }
}

enum GitBranchAction: Sendable {
    case fetch
    case pushTag(RepositoryReference, remote: String)
    case revision(RevisionAction)
    case skipIntegration(GitIntegration)
    case pull(RepositoryReference), push(RepositoryReference), stash
    case publish(RepositoryReference, remote: String, newURL: String? = nil)
    case stashEntry(StashEntryAction, GitStash)
    case replaySwitch(from: String, expectedHead: String, to: String)
    case deleteBranch(BranchDeletion, forceLocal: Bool)
    case worktree(WorktreeAction)
    case switchTo(String)
    case createAndSwitch(name: String, start: RepositoryReference)
    case track(name: String, remote: RepositoryReference)
    case resolve(GitConflict, ConflictResolution)
    case continueIntegration(GitIntegration)
    case abortIntegration(GitIntegration)

    var failureTitle: String {
        switch self {
        case .pushTag: "Couldn’t push tag"
        case .fetch: "Fetch failed"
        case .revision(let action): action.operation.rawValue + " stopped"
        case .skipIntegration: "Couldn’t skip commit"
        case .pull: "Pull failed"
        case .push, .publish: "Push failed"
        case .stash: "Couldn’t stash changes"
        case .stashEntry(.apply, _): "Couldn’t apply stash"
        case .stashEntry(.pop, _): "Couldn’t pop stash"
        case .stashEntry(.delete, _): "Couldn’t delete stash"
        case .switchTo, .replaySwitch: "Couldn’t switch branches"
        case .createAndSwitch, .track: "Couldn’t create branch"
        case .deleteBranch: "Couldn’t finish branch deletion"
        case .resolve: "Couldn’t stage conflict resolution"
        case .continueIntegration(let integration): "Couldn’t continue " + integration.rawValue
        case .abortIntegration(let integration): "Couldn’t abort " + integration.rawValue
        case .worktree(.stage): "Couldn’t stage changes"
        case .worktree(.unstage): "Couldn’t unstage changes"
        case .worktree(.commit): "Commit failed"
        case .worktree(.discardUnstaged): "Couldn’t discard changes"
        }
    }

    var pushDestination: String? {
        switch self {
        case .publish(let branch, let remote, _): return remote + "/" + branch.name
        case .push(let branch): return branch.upstreamTarget?.displayName
        case .revision(let action) where action.operation == .publish: return action.remoteName + "/" + action.name
        case .revision(let action) where action.operation.pushes: return action.target.name
        case .worktree(.commit(_, _, let push?)):
            switch push.route {
            case .publish(let remote, _, _): return remote + "/" + push.branch
            case .upstream(let target): return target.displayName
            }
        default: return nil
        }
    }

    var returnsToHistory: Bool {
        if pushDestination != nil { return false }
        if case .pushTag = self { return false }
        if case .revision(let action) = self, action.operation == .tag { return false }
        if case .fetch = self { return false }
        if case .worktree = self { return false }
        if case .resolve = self { return false }
        if case .stashEntry = self { return false }
        return true
    }

    var canPauseForConflicts: Bool {
        switch self {
        case .revision(let action): [.rebase, .merge, .cherryPick, .revert].contains(action.operation)
        case .continueIntegration, .skipIntegration: true
        default: false
        }
    }

    func run(in root: URL) async throws {
        let arguments: [String]
        switch self {
        case .pushTag(let tag, let remote):
            try await RevisionAction.pushTag(tag.name, at: tag.commitID, to: remote, in: root)
            return
        case .fetch: arguments = ["fetch", "--all"]
        case .revision(let action):
            try await action.run(in: root)
            return
        case .skipIntegration(let integration):
            arguments = [integration.gitCommand, "--skip"]
        case .publish(let branch, let remote, let url):
            guard branch.pushUpstream == nil, try await GitIntegration.read(in: root) == nil else {
                throw RepositoryReadError.commandFailed("The branch state changed. Review the push again.")
            }
            _ = try await reviewedUpstream(of: branch, in: root)
            let destination = CommitPushDestination(branch: branch.name, route: .publish(remote: remote, newURL: url))
            try await destination.configureRemoteIfNeeded(in: root)
            _ = try await GitRepository.git(["remote", "get-url", "--push", "--", remote], in: root)
            arguments = ["push", "--set-upstream", "--", remote, branch.id + ":" + branch.id]
        case .push(let branch):
            guard branch.pushUpstream != nil, try await GitIntegration.read(in: root) == nil,
                  let upstream = try await reviewedUpstream(of: branch, in: root) else {
                throw RepositoryReadError.commandFailed("The branch state changed. Review the push again.")
            }
            arguments = ["push", "--", upstream.remote, branch.commitID + ":" + upstream.ref]
        case .pull(let branch):
            let state = try await GitRepository.read(at: root)
            guard state.branch == branch.name, state.headID == branch.commitID, state.integration == nil,
                  let upstream = try await reviewedUpstream(of: branch, in: root) else {
                throw RepositoryReadError.commandFailed("The current branch or its upstream changed. Refresh and try again.")
            }
            arguments = ["pull", "--ff-only", "--no-rebase", "--", upstream.remote, upstream.ref]
        case .deleteBranch(let deletion, let forceLocal):
            try await deletion.run(in: root, forceLocal: forceLocal)
            return
        case .stash: arguments = ["stash", "push", "--include-untracked"]
        case .stashEntry(let action, let stash):
            try await action.run(on: stash, in: root)
            return
        case .replaySwitch(let branch, let head, let target):
            let state = try await GitRepository.read(at: root)
            guard state.branch == branch, state.headID == head, state.integration == nil else {
                throw RepositoryReadError.commandFailed("The branch changed. Refresh before switching.")
            }
            arguments = ["switch", "--no-guess", "--", target]
        case .worktree(let action):
            try await action.run(in: root)
            return
        case .switchTo(let name):
            arguments = ["switch", "--no-guess", "--", name]
        case .createAndSwitch(let name, let start):
            arguments = ["switch", "-c", name, "--", start.commitID]
        case .track(let name, let remote):
            arguments = ["switch", "--track", "-c", name, "--", remote.id]
        case .resolve(let conflict, let resolution):
            try await conflict.apply(resolution, in: root)
            return
        case .continueIntegration(let integration):
            arguments = ["-c", "core.editor=/usr/bin/true", integration.gitCommand, "--continue"]
        case .abortIntegration(let integration):
            arguments = [integration.gitCommand, "--abort"]
        }
        _ = try await GitRepository.git(arguments, in: root)
    }

    /// Validate the selected ref independently of the worktree's checked-out branch.
    private func reviewedUpstream(of branch: RepositoryReference, in root: URL) async throws -> RemoteBranchTarget? {
        let format = "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)"
        let data = try await GitRepository.git(["for-each-ref", format, branch.id], in: root)
        let fields = data.dropLast().split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard fields.count == 5, branch.kind == .local, fields[0] == branch.id, fields[1] == branch.commitID,
              fields[2] == (branch.upstreamID ?? "") else {
            throw RepositoryReadError.commandFailed("The branch or its upstream changed. Refresh and try again.")
        }
        guard branch.upstreamID != nil else { return nil }
        guard !fields[3].isEmpty, fields[4].hasPrefix("refs/heads/") else {
            throw RepositoryReadError.commandFailed("The upstream does not identify a destination branch.")
        }
        let upstream = RemoteBranchTarget(remote: fields[3], ref: fields[4])
        guard upstream == branch.upstreamTarget else {
            throw RepositoryReadError.commandFailed("The remote destination changed. Review the branch again.")
        }
        return upstream
    }
}

struct RemoteBranchTarget: Hashable, Sendable {
    let remote: String
    let ref: String
    var name: String { String(ref.dropFirst("refs/heads/".count)) }
    var displayName: String { remote == "." ? name : remote + "/" + name }

    static func resolve(_ branch: RepositoryReference, in root: URL) async throws -> Self {
        let mappings = try await fetchMappings(in: root)
        guard let target = resolve(refID: branch.id, mappings: mappings) else {
            throw RepositoryReadError.commandFailed("Git’s fetch configuration does not identify a unique remote branch for " + branch.name + ".")
        }
        return target
    }

    static func fetchMappings(in root: URL) async throws -> [String: [String]] {
        let data = try await GitRepository.git(["config", "--null", "--get-regexp", "^remote\\..*\\.fetch$"], in: root, accepting: [0, 1])
        var mappings: [String: [String]] = [:]
        for record in data.split(separator: 0) {
            let fields = String(decoding: record, as: UTF8.self).split(separator: "\n", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let remote = String(fields[0].dropFirst("remote.".count).dropLast(".fetch".count))
            mappings[remote, default: []].append(String(fields[1]))
        }
        return mappings
    }

    static func resolve(refID: String, mappings: [String: [String]]) -> Self? {
        var matches: Set<Self> = []
        for (remote, specs) in mappings {
            for spec in specs where !spec.hasPrefix("^") {
                let pair = spec.drop(while: { $0 == "+" }).split(separator: ":", maxSplits: 1)
                guard pair.count == 2, let wildcard = match(String(pair[1]), refID) else { continue }
                let source = String(pair[0]).replacingOccurrences(of: "*", with: wildcard)
                guard source.hasPrefix("refs/heads/"),
                      !specs.contains(where: { $0.hasPrefix("^") && match(String($0.dropFirst()), source) != nil }) else { continue }
                matches.insert(Self(remote: remote, ref: source))
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private static func match(_ pattern: String, _ ref: String) -> String? {
        guard let star = pattern.firstIndex(of: "*") else { return pattern == ref ? "" : nil }
        let prefix = pattern[..<star], suffix = pattern[pattern.index(after: star)...]
        guard ref.hasPrefix(prefix), ref.hasSuffix(suffix), ref.count >= prefix.count + suffix.count else { return nil }
        return String(ref.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

struct BranchDeletion: Identifiable, Sendable {
    struct ID: Hashable {
        let local: String?
        let remote: String?
        let worktree: URL?
    }
    var id: ID { ID(local: local?.id, remote: remoteRef?.id, worktree: worktree?.id) }
    let local: RepositoryReference?
    let remoteRef: RepositoryReference?
    let worktree: GitWorktree?
    let commandRoot: URL
    private(set) var remote: RemoteBranchTarget?

    var title: String {
        switch (worktree != nil, local != nil, remoteRef != nil) {
        case (true, true, true): "Delete Worktree, Local and Remote Branches"
        case (true, true, false): "Delete Worktree and Local Branch"
        case (true, false, true): "Delete Worktree and Remote Branch"
        case (true, false, false): "Delete Worktree Only"
        case (false, true, true): "Delete Local and Remote Branches"
        case (false, true, false): "Delete Local Branch"
        default: "Delete Remote Branch"
        }
    }

    static func choices(for ref: RepositoryReference, in snapshot: RepositorySnapshot) -> [Self] {
        guard ref.kind != .tag else { return [] }
        let root = snapshot.repository.root
        let local: RepositoryReference?
        let remote: RepositoryReference?
        if ref.kind == .local {
            local = ref
            if let upstream = ref.upstreamID {
                remote = snapshot.references.first { $0.kind == .remote && $0.id == upstream }
            } else {
                let matches = snapshot.references.filter { $0.kind == .remote && $0.remoteTarget?.name == ref.name }
                remote = matches.count == 1 ? matches.first : nil
            }
        } else {
            remote = ref
            let tracking = snapshot.references.filter { $0.kind == .local && $0.upstreamID == ref.id }
            if tracking.isEmpty {
                local = snapshot.references.first { $0.kind == .local && $0.upstreamID == nil && $0.name == ref.remoteTarget?.name }
            } else {
                local = tracking.count == 1 ? tracking.first : nil
            }
        }
        var options: [Self] = []
        let checkouts = snapshot.worktrees.filter { $0.branch == local?.name }
        if let local, checkouts.isEmpty, local.name != snapshot.repository.branch {
            options.append(Self(local: local, remoteRef: nil, worktree: nil, commandRoot: root))
            if let remote { options.append(Self(local: local, remoteRef: remote, worktree: nil, commandRoot: root)) }
        }
        if let remote { options.append(Self(local: nil, remoteRef: remote, worktree: nil, commandRoot: root)) }
        if let local, checkouts.count == 1, let tree = checkouts.first, !tree.isMain, !tree.isLocked {
            let commandRoot = tree.id.path == root.path ? snapshot.worktrees.first { $0.id.path != root.path }?.id : root
            if let commandRoot {
                options.append(Self(local: nil, remoteRef: nil, worktree: tree, commandRoot: commandRoot))
                options.append(Self(local: local, remoteRef: nil, worktree: tree, commandRoot: commandRoot))
                if let remote {
                    options.append(Self(local: nil, remoteRef: remote, worktree: tree, commandRoot: commandRoot))
                    options.append(Self(local: local, remoteRef: remote, worktree: tree, commandRoot: commandRoot))
                }
            }
        }
        return options
    }

    func reviewed() async throws -> Self {
        var result = self
        if let remoteRef {
            let target = try await RemoteBranchTarget.resolve(remoteRef, in: commandRoot)
            guard target == remoteRef.remoteTarget else {
                throw RepositoryReadError.commandFailed("The remote branch mapping changed. Refresh and try again.")
            }
            result.remote = target
        }
        return result
    }

    private func verifyTip(_ branch: RepositoryReference) async throws {
        let tip = try await GitRepository.git(["show-ref", "--verify", "--hash", branch.id], in: commandRoot)
        guard String(decoding: tip.dropLast(), as: UTF8.self) == branch.commitID else {
            throw RepositoryReadError.commandFailed("The branch “" + branch.name + "” moved. Review its new tip before deleting it.")
        }
    }

    func run(in root: URL, forceLocal: Bool) async throws {
        guard try await GitIntegration.read(in: commandRoot) == nil else {
            throw RepositoryReadError.commandFailed("Finish the current Git operation before deleting a branch.")
        }
        let trees = try await GitHistory.worktrees(in: commandRoot)
        guard trees.contains(where: { $0.id.path == root.path }) else {
            throw RepositoryReadError.commandFailed("The worktree registration changed. Refresh and try again.")
        }
        if let local {
            try await verifyTip(local)
            guard trees.allSatisfy({ $0.branch != local.name || $0 == worktree }) else {
                throw RepositoryReadError.commandFailed("The branch is checked out in another worktree.")
            }
            if !forceLocal {
                // Both refs may disappear. Verify against the checkout that will survive.
                var base = "HEAD"
                if remoteRef == nil, let upstream = local.upstreamID,
                   try await !GitRepository.git(["show-ref", "--verify", "--hash", upstream], in: commandRoot, accepting: [0, 1, 128]).isEmpty {
                    base = upstream
                }
                let merged = try await GitRepository.git(["merge-base", local.commitID, base], in: commandRoot, accepting: [0, 1])
                guard String(decoding: merged.dropLast(), as: UTF8.self) == local.commitID else {
                    throw RepositoryReadError.commandFailed("The local branch has unmerged commits. Review them or allow unmerged deletion.")
                }
            }
        }
        if let remoteRef {
            try await verifyTip(remoteRef)
            guard let remote, try await RemoteBranchTarget.resolve(remoteRef, in: commandRoot) == remote else {
                throw RepositoryReadError.commandFailed("The remote branch mapping changed. Review the deletion again.")
            }
        }
        var completed: [String] = []
        do {
            if let worktree {
                guard !worktree.isMain, !worktree.isLocked, worktree.id.path != commandRoot.path,
                      trees.contains(worktree) else {
                    throw RepositoryReadError.commandFailed("The worktree changed or is locked. Refresh and try again.")
                }
                let checkout = try await GitRepository.read(at: worktree.id)
                guard checkout.root.path == worktree.id.path, checkout.branch == worktree.branch,
                      checkout.integration == nil, checkout.changes.isEmpty else {
                    throw RepositoryReadError.commandFailed("The worktree must be clean and on the reviewed branch before removal.")
                }
                _ = try await GitRepository.git(["worktree", "remove", "--", worktree.id.path], in: commandRoot)
                completed.append("Removed worktree “" + worktree.id.path + "”.")
            }
            if let remote, let remoteRef {
                _ = try await GitRepository.git(["-c", "remote." + remote.remote + ".mirror=false", "push", "--no-follow-tags",
                    "--force-with-lease=" + remote.ref + ":" + remoteRef.commitID, "--", remote.remote, ":" + remote.ref], in: commandRoot)
                completed.append("Deleted “" + remoteRef.name + "” on the remote.")
            }
            if let local {
                try await verifyTip(local)
                _ = try await GitRepository.git(["branch", forceLocal ? "-D" : "-d", "--", local.name], in: commandRoot)
            }
        } catch {
            guard !completed.isEmpty else { throw error }
            throw RepositoryReadError.commandFailed(completed.joined(separator: " ") + "\n\n" + error.localizedDescription)
        }
    }
}

enum StashEntryAction: Sendable {
    case apply, pop, delete

    func run(on stash: GitStash, in root: URL) async throws {
        if self != .delete {
            let repo = try await GitRepository.read(at: root)
            guard repo.integration == nil, !repo.changes.contains(where: { $0.staged == .conflict }) else {
                throw RepositoryReadError.commandFailed("Finish the current Git operation before applying a stash.")
            }
            _ = try await liveEntry(for: stash, in: root)
            // A new stash can renumber every selector. Apply the reviewed commit by ID.
            do {
                _ = try await GitRepository.git(["stash", "apply", "--index", stash.id], in: root)
            } catch {
                throw RepositoryReadError.commandFailed("The stash was kept. " + error.localizedDescription)
            }
        }
        guard self != .apply else { return }
        do {
            let entry = try await liveEntry(for: stash, in: root)
            _ = try await GitRepository.git(["stash", "drop", entry.selector], in: root)
        } catch {
            if self == .pop {
                throw RepositoryReadError.commandFailed("Changes were applied. Check the stash list before trying again. " + error.localizedDescription)
            }
            throw error
        }
    }

    private func liveEntry(for stash: GitStash, in root: URL) async throws -> GitStash {
        let entries = try await GitHistory.stashes(in: root)
        let matches = entries.filter { $0.id == stash.id && $0.subject == stash.subject }
        if let entry = matches.first(where: { $0.selector == stash.selector }) { return entry }
        if matches.count == 1 { return matches[0] }
        throw RepositoryReadError.commandFailed("The stash list changed. Select the stash again.")
    }
}
