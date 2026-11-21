import Foundation

struct CommitMessage: Equatable, Sendable {
    var summary = ""
    var body = ""
}

struct CommitDraft: Sendable {
    var message = CommitMessage()
    var amendment: CommitMessage?
    var amendHead: String?
    var signOff = false

    var active: CommitMessage {
        get { amendment ?? message }
        set {
            if amendment != nil { amendment = newValue }
            else { message = newValue }
        }
    }
}

enum WorktreeAction: Sendable {
    case stage([String]?)
    case unstage([String]?)
    case discardUnstaged([FileChange])
    case commit(CommitDraft, expectedHead: String?)

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
        case .commit(let draft, let head):
            guard head == repo.headID, draft.amendment == nil || (head != nil && draft.amendHead == head) else {
                throw RepositoryReadError.commandFailed("HEAD changed. Review the current commit before committing.")
            }
            let message = draft.active
            let summary = message.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { throw RepositoryReadError.commandFailed("Enter a commit summary.") }
            args = ["commit"] + (draft.amendment == nil ? [] : ["--amend"]) + (draft.signOff ? ["--signoff"] : [])
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
    }
}
