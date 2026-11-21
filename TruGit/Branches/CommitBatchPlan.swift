import Foundation

enum CommitBatchOperation: String, CaseIterable, Sendable {
    case cherryPick = "Cherry-pick"
    case revert = "Revert"

    var revisionOperation: RevisionOperation { self == .revert ? .revert : .cherryPick }
    var gitCommand: String { rawValue.lowercased() }

    func ordered(_ parentFirst: [GitCommit]) -> [GitCommit] {
        self == .revert ? Array(parentFirst.reversed()) : parentFirst
    }
}

struct CommitBatchPlan: Sendable {
    let commits: [GitCommit]
    let squashMessage: String?

    // A native sequencer label survives a conflict and disappears on finish or abort.
    static let label = "trugit-squash-cherry-pick"

    func run(_ operation: CommitBatchOperation, in root: URL, onto target: RevisionPoint, mainline: Int?) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("commits")
        if operation == .cherryPick, let squashMessage {
            try await squash(in: root, onto: target, mainline: mainline, message: squashMessage, todoFile: file)
        } else {
            // --stdin also works for selections larger than the process argument limit.
            let list = commits.map(\.id).joined(separator: "\n") + "\n"
            try Data(list.utf8).write(to: file, options: .withoutOverwriting)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let parent = mainline.map { ["-m", String($0)] } ?? []
            _ = try await GitRepository.git([operation.gitCommand, "--no-edit", "--no-walk=unsorted"] + parent + ["--stdin"],
                                            in: root, standardInput: handle)
        }
    }

    private func squash(in root: URL, onto target: RevisionPoint, mainline: Int?, message: String, todoFile: URL) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryReadError.commandFailed("Enter a message for the squashed commit.")
        }
        let tree = try await objectID(["rev-parse", "--verify", target.oid + "^{tree}"], in: root)
        // Start with an empty commit carrying the reviewed message. Every selected patch
        // can then be skipped or fixed up, including the very first one.
        let seed = try await objectID(["commit-tree", tree, "-p", target.oid, "-m", message], in: root)
        var lines = ["label " + Self.label, "pick " + seed]
        for commit in commits {
            var oid = commit.id
            if commit.parents.count > 1 {
                guard let mainline, commit.parents.indices.contains(mainline - 1) else {
                    throw RepositoryReadError.commandFailed("Choose a valid mainline parent for the merge commit.")
                }
                // Express the merge's change relative to the reviewed parent as a
                // single-parent patch that Git's fixup instruction can replay.
                let tree = try await objectID(["rev-parse", commit.id + "^{tree}"], in: root)
                oid = try await objectID(["commit-tree", tree, "-p", commit.parents[mainline - 1], "-m", commit.subject], in: root)
            }
            lines.append("fixup " + oid)
        }
        // Leave the target at its original tip if every patch was skipped or cancels out.
        lines.append("exec test \"$(git rev-parse 'HEAD^{tree}')\" != " + tree + " || git reset --soft " + target.oid)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: todoFile, options: .withoutOverwriting)
        try await target.validate(in: root)
        _ = try await GitRepository.git([
            "-c", "rebase.abbreviateCommands=false", "-c", "rebase.missingCommitsCheck=error",
            "rebase", "--interactive", "--force-rebase", "--no-rebase-merges", "--no-autosquash",
            "--no-autostash", "--no-update-refs", "--keep-empty", target.oid, target.name
        ], in: root, environment: ["TRUGIT_PICK_TODO": todoFile.path, "GIT_SEQUENCE_EDITOR": "/bin/cp \"$TRUGIT_PICK_TODO\"",
                                   "GIT_EDITOR": "/usr/bin/true"])
    }

    private func objectID(_ arguments: [String], in root: URL) async throws -> String {
        let data = try await GitRepository.git(arguments, in: root)
        let oid = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard [40, 64].contains(oid.count), oid.allSatisfy(\.isHexDigit) else { throw RepositoryReadError.invalidOutput }
        return oid
    }
}
