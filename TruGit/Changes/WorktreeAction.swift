import Foundation

struct CommitMessage: Equatable, Sendable {
    var summary = ""
    var body = ""
}

struct CommitDraft: Sendable {
    var message = CommitMessage()
    var amendment: CommitMessage?
    var amendHead: String?

    var active: CommitMessage {
        get { amendment ?? message }
        set {
            if amendment != nil { amendment = newValue }
            else { message = newValue }
        }
    }
}

struct CommitPushDestination: Sendable {
    let branch: String
    enum Route: Sendable {
        case upstream(RemoteBranchTarget)
        case publish(remote: String, newURL: String? = nil, replacingUpstream: String? = nil)
    }

    let route: Route

    static func validRemoteURL(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains(where: { $0.isNewline }), !value.contains("\0") else { return false }
        if value.hasPrefix("/") { return true }
        if value.contains("://") {
            guard let url = URLComponents(string: value), let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "file" ? url.path.hasPrefix("/") :
                ["https", "http", "ssh", "git"].contains(scheme) && !(url.host ?? "").isEmpty
        }
        // Git also accepts SCP-style SSH addresses such as git@host:team/repo.git.
        guard let colon = value.firstIndex(of: ":") else { return false }
        let host = value[..<colon], path = value[value.index(after: colon)...]
        return !host.isEmpty && !host.hasPrefix("-") && !host.contains("/") && !host.contains(where: \.isWhitespace)
            && !path.isEmpty && !path.hasPrefix(":")
    }

    func configureRemoteIfNeeded(in root: URL) async throws {
        guard case .publish(let remote, let url?, _) = route else { return }
        guard Self.validRemoteURL(url) else { throw RepositoryReadError.commandFailed("Enter a valid Git remote URL or an absolute repository path.") }
        let configured = try await GitRepository.git(["remote"], in: root)
        if String(decoding: configured, as: UTF8.self).split(separator: "\n").contains(Substring(remote)) {
            let current = try await GitRepository.git(["remote", "get-url", "--push", "--all", "--", remote], in: root)
            guard String(decoding: current, as: UTF8.self).split(separator: "\n") == [Substring(url)] else {
                throw RepositoryReadError.commandFailed("The push address for “" + remote + "” changed. Review the destination again.")
            }
        } else {
            _ = try await GitRepository.git(["remote", "add", "--", remote, url], in: root)
        }
    }

    func pushCommittedChanges(in root: URL) async throws {
        var action: GitBranchAction?
        do {
            let refs = try await GitHistory.references(in: root)
            guard let ref = refs.first(where: { $0.kind == .local && $0.name == branch }) else {
                throw RepositoryReadError.commandFailed("The local branch changed. Review the destination before pushing.")
            }
            let push: GitBranchAction
            switch route {
            case .upstream(let upstream) where upstream == ref.pushUpstream:
                push = .push(ref)
            case .publish(let publishRemote, _, let previous) where ref.pushUpstream == nil && ref.upstreamID == previous:
                push = .publish(ref, remote: publishRemote)
            default:
                throw RepositoryReadError.commandFailed("The upstream changed. Review the destination before pushing.")
            }
            action = push
            try await push.run(in: root)
        } catch {
            throw CommitPushFailure(message: error.localizedDescription, push: action)
        }
    }
}

struct CommitPushFailure: LocalizedError {
    let message: String
    let push: GitBranchAction?
    var errorDescription: String? { message }
}

enum WorktreeAction: Sendable {
    case stage([String]?)
    case unstage([String]?)
    case discardUnstaged([FileChange])
    case commit(CommitDraft, expectedHead: String?, push: CommitPushDestination? = nil)

    func run(in root: URL) async throws {
        let repo = try await GitRepository.read(at: root)
        guard repo.integration == nil, !repo.changes.contains(where: { $0.staged == .conflict }) else {
            throw RepositoryReadError.commandFailed("Resolve the current Git operation before changing the index here.")
        }
        let args: [String]
        switch self {
        case .stage(let paths):
            args = ["--literal-pathspecs", "add", "-A", "--"] + (paths ?? ["."])
        case .unstage(let paths):
            args = ["--literal-pathspecs", "reset", "-q", "--"] + (paths ?? ["."])
        case .commit(let draft, let head, let destination):
            guard destination == nil || destination?.branch == repo.branch else {
                throw RepositoryReadError.commandFailed("The current branch changed. Review your staged changes again.")
            }
            guard head == repo.headID, draft.amendment == nil || (head != nil && draft.amendHead == head) else {
                throw RepositoryReadError.commandFailed("HEAD changed. Review the current commit before committing.")
            }
            let message = draft.active
            let summary = message.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { throw RepositoryReadError.commandFailed("Enter a commit summary.") }
            try await destination?.configureRemoteIfNeeded(in: root)
            args = ["commit"] + (draft.amendment == nil ? [] : ["--amend"])
                + ["-m", summary] + (message.body.isEmpty ? [] : ["-m", message.body])
        case .discardUnstaged(let reviewed):
            let current = Dictionary(uniqueKeysWithValues: repo.changes.map { ($0.id, $0) })
            let unstaged = reviewed
            guard !unstaged.isEmpty, unstaged.allSatisfy({ $0.workingTree != nil && current[$0.id] == $0 }) else {
                throw RepositoryReadError.commandFailed("The file list changed. Review the unstaged changes again.")
            }
            let newFiles = unstaged.filter { $0.workingTree == .untracked }
            for file in newFiles {
                let values = try root.appendingPathComponent(file.path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory != true || values.isSymbolicLink == true else {
                    throw RepositoryReadError.commandFailed("Manage the untracked directory \(file.path) separately.")
                }
            }
            let tracked = unstaged.filter { $0.workingTree != .untracked }.map(\.path)
            if !tracked.isEmpty {
                _ = try await GitRepository.git(["--literal-pathspecs", "restore", "--worktree", "--"] + tracked, in: root)
            }
            for file in newFiles {
                try FileManager.default.trashItem(at: root.appendingPathComponent(file.path), resultingItemURL: nil)
            }
            return
        }
        _ = try await GitRepository.git(args, in: root)
        if case .commit(_, _, let destination) = self { try await destination?.pushCommittedChanges(in: root) }
    }
}
