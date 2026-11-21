import Foundation

/// A ref and the exact revision the user saw when opening the action panel.
struct RevisionPoint: Hashable, Identifiable {
    let reference: RepositoryReference?
    let oid: String
    let name: String
    var id: String { reference?.id ?? oid }
    var isLocal: Bool { reference?.kind == .local }
    var isRemote: Bool { reference?.kind == .remote }
    var shortID: String { String(oid.prefix(8)) }
    var icon: String { reference?.kind.icon ?? "circle.circle" }

    init(_ ref: RepositoryReference) {
        reference = ref
        oid = ref.commitID
        name = ref.name
    }

    init(commit: String) {
        reference = nil
        oid = commit
        name = String(commit.prefix(8))
    }

    func validate(in root: URL) async throws {
        guard let reference else { return }
        let data = try await GitRepository.git(["rev-parse", "--verify", reference.id + "^{commit}"], in: root)
        guard String(decoding: data.dropLast(), as: UTF8.self) == oid else {
            throw RepositoryReadError.commandFailed("“" + name + "” moved. Open Branch Actions again to review its latest commit.")
        }
    }
}

enum RevisionOperation: String, Hashable, CaseIterable, Identifiable {
    case merge = "Merge"
    case fastForward = "Fast-forward"
    case rebase = "Rebase"
    case cherryPick = "Cherry-pick"
    case revert = "Revert commit"
    case push = "Push"
    case forcePush = "Force push with lease"
    case checkout = "Switch branch"
    case reset = "Reset branch"
    case createBranch = "Create branch"
    case rename = "Rename branch"
    case tag = "Create tag"
    case publish = "Publish branch"

    var namesRef: Bool { self == .createBranch || self == .rename || self == .tag || self == .publish }

    var id: Self { self }
    var isResetOrRevert: Bool { self == .reset || self == .revert }
    var pushes: Bool { self == .push || self == .forcePush || self == .publish }
    func checkoutBranch(source: RevisionPoint, target: RevisionPoint) -> RevisionPoint? {
        switch self {
        case .checkout, .rebase: source
        case .merge, .fastForward, .cherryPick, .revert, .reset: target
        default: nil
        }
    }

    var usesMainline: Bool { self == .cherryPick || self == .revert }

    var icon: String {
        switch self {
        case .merge: "arrow.triangle.merge"
        case .fastForward: "forward.end"
        case .rebase: "arrow.turn.up.right"
        case .cherryPick: "arrow.down.to.line"
        case .revert: "arrow.uturn.backward"
        case .push, .publish: "arrow.up.to.line"
        case .forcePush: "arrow.up.circle.fill"
        case .checkout: "arrow.triangle.branch"
        case .reset: "clock.arrow.circlepath"
        case .createBranch: "plus"
        case .rename: "pencil"
        case .tag: "tag"
        }
    }

    func available(from source: RevisionPoint, to target: RevisionPoint, current: String) -> Bool {
        switch self {
        case .createBranch, .tag: true
        case .rename, .publish: source.isLocal
        case .checkout: source.isLocal && source.name != current
        case .rebase: source.isLocal && source.id != target.id
        case .push, .forcePush: source.isLocal && target.isRemote && target.reference?.remoteTarget != nil
        case .reset: target.isLocal
        case .revert: target.isLocal
        case .cherryPick, .merge, .fastForward: target.isLocal && source.id != target.id
        }
    }

    func explanation(_ source: RevisionPoint, _ target: RevisionPoint) -> String {
        switch self {
        case .merge: "Merge “\(source.name)” into “\(target.name)” with a merge commit."
        case .fastForward: "Advance “\(target.name)” to \(source.shortID) only if its history is a direct ancestor."
        case .rebase: "Replay the commits from “\(source.name)” on top of “\(target.name)”. This rewrites “\(source.name)”."
        case .cherryPick: "Apply the changes from commit \(source.shortID) as a new commit on “\(target.name)”."
        case .revert: "Create a commit on “\(target.name)” that reverses the changes introduced by \(source.shortID)."
        case .push: "Push “\(source.name)” to “\(target.name)”. Git checks that the remote can fast-forward."
        case .forcePush: "Replace “\(target.name)” with \(source.shortID). Remote-only commits can be removed. Git will refuse if the remote has moved from \(target.shortID)."
        case .publish: "Create a remote branch from “\(source.name)” and set it as the upstream. The remote branch name must be new."
        case .createBranch: "Create a local branch at \(source.shortID) and keep your current branch checked out."
        case .rename: "Rename local branch “\(source.name)”. Its remote branch keeps its existing name."
        case .tag: "Tag commit \(source.shortID). Add a message to create an annotated tag."
        case .reset: "Reset “\(target.name)” from \(target.shortID) to \(source.shortID)."
        case .checkout: "Switch this worktree to “\(source.name)”."
        }
    }
}

enum BranchResetMode: String, CaseIterable, Identifiable {
    case soft, mixed, hard
    var id: Self { self }
    var detail: String {
        switch self {
        case .soft: "Keep staged changes and working files as they are. Moving back leaves the changes from later commits staged."
        case .mixed: "Keep working files and reset the index. Changes become unstaged."
        case .hard: "Replace the index and tracked files. Uncommitted edits and untracked files blocking checkout may be lost."
        }
    }
}

struct RevisionAction {
    let operation: RevisionOperation
    let source: RevisionPoint
    let target: RevisionPoint
    let mainline: Int?
    var reviewedWorktree: URL?
    var batchPlan: CommitBatchPlan?
    var resetMode: BranchResetMode = .soft
    var name = ""
    var tagMessage = ""
    var remoteName = ""

    func run(in root: URL) async throws {
        if let reviewedWorktree, reviewedWorktree.resolvingSymlinksInPath() != root.resolvingSymlinksInPath() {
            throw RepositoryReadError.commandFailed("The destination worktree changed. Review the action again.")
        }
        guard try await GitIntegration.read(in: root) == nil else {
            throw RepositoryReadError.commandFailed("Finish the current Git operation first.")
        }
        try await source.validate(in: root)
        if operation.namesRef {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("@{-") else {
                throw RepositoryReadError.commandFailed("Enter a valid Git reference name.")
            }
            let args: [String]
            switch operation {
            case .publish:
                guard source.isLocal, !remoteName.isEmpty else { throw RepositoryReadError.commandFailed("Choose a remote.") }
                let configured = try await GitRepository.git(["remote"], in: root)
                guard String(decoding: configured, as: UTF8.self).split(separator: "\n").contains(Substring(remoteName)) else {
                    throw RepositoryReadError.commandFailed("The selected remote is no longer configured.")
                }
                let destination = "refs/heads/" + name
                _ = try await GitRepository.git(["check-ref-format", destination], in: root)
                args = ["push", "--set-upstream", "--force-with-lease=" + destination + ":", "--", remoteName,
                        source.id + ":" + destination]
            case .rename:
                guard source.isLocal else { throw RepositoryReadError.commandFailed("Choose a local branch to rename.") }
                args = ["branch", "-m", "--", source.name, name]
            case .createBranch: args = ["branch", "--", name, source.oid]
            case .tag:
                let annotation = tagMessage.isEmpty ? [] : ["-a", "-m", tagMessage]
                args = ["tag"] + annotation + ["--", name, source.oid]
            default: throw RepositoryReadError.invalidOutput
            }
            _ = try await GitRepository.git(args, in: root)
            return
        }
        if operation == .checkout {
            try await switchTo(source, in: root)
            return
        }
        try await target.validate(in: root)
        if operation.pushes {
            guard source.isLocal, let ref = target.reference, ref.kind == .remote,
                  let remote = ref.remoteTarget, try await RemoteBranchTarget.resolve(ref, in: root) == remote else {
                throw RepositoryReadError.commandFailed("The remote branch mapping changed. Review the destination again.")
            }
            let lease = "--force-with-lease=" + remote.ref + ":" + target.oid
            let options = operation == .forcePush ? [lease] : []
            _ = try await GitRepository.git(["push"] + options + ["--", remote.remote, source.oid + ":" + remote.ref], in: root)
            return
        }
        if operation == .reset, resetMode == .hard {
            let repo = try await GitRepository.read(at: root)
            guard repo.branch == target.name || repo.changes.isEmpty else {
                throw RepositoryReadError.commandFailed("Switch to the target branch first or save this worktree’s uncommitted changes.")
            }
        }
        guard let branch = operation.checkoutBranch(source: source, target: target) else { throw RepositoryReadError.invalidOutput }
        try await switchTo(branch, in: root)
        let arguments: [String]
        switch operation {
        case .rebase:
            arguments = ["rebase", "--no-autostash", "--no-update-refs", target.oid]
        case .merge:
            arguments = ["merge", "--no-ff", "--no-squash", "--no-autostash", "--no-edit", "-m",
                         "Merge \(source.reference == nil ? "commit" : "branch") '\(source.name)' into '\(target.name)'", "--", source.oid]
        case .fastForward:
            arguments = ["merge", "--ff-only", "--no-squash", "--no-autostash", "--", source.oid]
        case .cherryPick, .revert:
            let parent = mainline.map { ["-m", String($0)] } ?? []
            if let batchPlan {
                try await batchPlan.run(operation == .revert ? .revert : .cherryPick, in: root, onto: target, mainline: mainline)
                return
            }
            arguments = [operation == .cherryPick ? "cherry-pick" : "revert", "--no-edit"] + parent + [source.oid]
        case .reset:
            arguments = ["reset", "--" + resetMode.rawValue, source.oid]
        case .push, .forcePush, .publish, .checkout, .rename, .tag, .createBranch: return
        }
        _ = try await GitRepository.git(arguments, in: root)
    }

    private func switchTo(_ point: RevisionPoint, in root: URL) async throws {
        guard point.isLocal else { throw RepositoryReadError.commandFailed("Choose a local branch for this operation.") }
        let head = try await GitRepository.git(["symbolic-ref", "-q", "HEAD"], in: root, accepting: [0, 1])
        if String(decoding: head.dropLast(), as: UTF8.self) != point.id {
            guard reviewedWorktree == nil else {
                throw RepositoryReadError.commandFailed("“" + point.name + "” is no longer checked out here. Review the action again.")
            }
            try await GitBranchAction.switchTo(point.name).run(in: root)
        }
    }
}
