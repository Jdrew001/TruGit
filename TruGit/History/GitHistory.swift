import Foundation

struct RepositoryReference: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case local = "Local Branches"
        case remote = "Remote Branches"
        case tag = "Tags"

        var label: String {
            switch self {
            case .local: "Local"
            case .remote: "Remote"
            case .tag: "Tag"
            }
        }

        var prefix: String {
            switch self {
            case .local: "refs/heads/"
            case .remote: "refs/remotes/"
            case .tag: "refs/tags/"
            }
        }

        var icon: String {
            switch self {
            case .local: "arrow.triangle.branch"
            case .remote: "network"
            case .tag: "tag"
            }
        }
    }

    let id: String
    let name: String
    let kind: Kind
    let commitID: String
    let upstreamID: String?
    var upstreamTarget: RemoteBranchTarget? = nil
    var remoteTarget: RemoteBranchTarget? = nil

    // Compare the branch on the server, even with a custom fetch refspec.
    var pushUpstream: RemoteBranchTarget? {
        guard kind == .local, upstreamID != nil, let target = upstreamTarget, target.remote != ".", target.ref == id else { return nil }
        return target
    }
    var isGitHubRemote = false
    var locationLabel: String { isGitHubRemote ? "GitHub remote" : kind.label }
}

struct GitCommit: Identifiable, Hashable, Sendable {
    let id: String
    let parents: [String]
    let author: String
    let date: Date?
    let subject: String
    let message: String

    var mergeRoute: String? {
        guard parents.count == 2, subject.hasPrefix("Merge branch '"), subject.hasSuffix("'") else { return nil }
        let names = subject.dropFirst("Merge branch '".count).dropLast().components(separatedBy: "' into '")
        guard names.count == 2 else { return nil }
        return "\(names[0]) → \(names[1])"
    }

    var authorInitials: String { author.split(whereSeparator: \.isWhitespace).compactMap(\.first).prefix(2).map { String($0).uppercased() }.joined() }

    var shortID: String { String(id.prefix(7)) }
}

struct CommitFile: Identifiable, Sendable {
    let path: String
    let originalPath: String?
    var unchanged = false
    let status: FileChange.Status

    var id: String { path }
}

struct GitWorktree: Identifiable, Equatable, Sendable {
    let id: URL
    let branch: String
    let isMain: Bool
    let isLocked: Bool

    static func otherCheckout(of branch: String, in worktrees: [Self], outside root: URL) -> Self? {
        let matches = worktrees.filter { $0.branch == branch }
        let here = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard !matches.contains(where: { $0.id.resolvingSymlinksInPath().standardizedFileURL.path == here }) else { return nil }
        return matches.first
    }
}

struct TreeComparison: Hashable, Sendable {
    let base: String?
    let tip: String

    func arguments(options: [String], paths: [String] = []) -> [String] {
        if let base { return ["diff"] + options + [base, tip, "--"] + paths }
        return ["diff-tree", "--root", "--no-commit-id", "-r"] + options + [tip, "--"] + paths
    }
}

struct StashPart: Hashable, Sendable {
    enum Kind: String, Sendable { case staged = "Staged", unstaged = "Unstaged", untracked = "Untracked" }
    let kind: Kind
    let trees: TreeComparison
}

struct GitStash: Identifiable, Hashable, Sendable {
    let id: String
    let selector: String
    let subject: String
    let parts: [StashPart]
}

enum GitHistory {
    static func worktrees(in root: URL) async throws -> [GitWorktree] {
        let data = try await GitRepository.git(["worktree", "list", "--porcelain", "-z"], in: root)
        var path: String?
        var branch = "Detached HEAD"
        var result: [GitWorktree] = []
        var isMain = true
        var locked = false
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            let text = String(decoding: field, as: UTF8.self)
            if text.hasPrefix("worktree ") { path = String(text.dropFirst(9)); branch = "Detached HEAD" }
            else if text.hasPrefix("branch refs/heads/") { branch = String(text.dropFirst("branch refs/heads/".count)) }
            else if text == "bare" { path = nil; isMain = false }
            else if text == "locked" || text.hasPrefix("locked ") { locked = true }
            else if text.isEmpty, let folder = path {
                result.append(GitWorktree(id: URL(fileURLWithPath: folder, isDirectory: true), branch: branch, isMain: isMain, isLocked: locked))
                path = nil
                isMain = false
                locked = false
            }
        }
        return result
    }

    static func stashes(in root: URL) async throws -> [GitStash] {
        let data = try await GitRepository.git(["stash", "list", "-z", "--no-patch", "--format=%H%x00%gd%x00%gs%x00%P"], in: root)
        guard !data.isEmpty else { return [] }
        let fields = data.dropLast().split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard data.last == 0, fields.count.isMultiple(of: 4) else { throw RepositoryReadError.invalidOutput }
        return try stride(from: 0, to: fields.count, by: 4).map { index in
            let parents = fields[index + 3].split(separator: " ").map(String.init)
            guard parents.count >= 2 else { throw RepositoryReadError.invalidOutput }
            let tip = fields[index]
            var parts = [
                StashPart(kind: .staged, trees: .init(base: parents[0], tip: parents[1])),
                StashPart(kind: .unstaged, trees: .init(base: parents[1], tip: tip))
            ]
            if parents.count > 2 { parts.append(.init(kind: .untracked, trees: .init(base: nil, tip: parents[2]))) }
            return GitStash(id: tip, selector: fields[index + 1], subject: fields[index + 2], parts: parts)
        }
    }

    static let pageSize = 200

    static func references(in root: URL) async throws -> [RepositoryReference] {
        let output = try await GitRepository.git([
            "for-each-ref",
            "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00%(symref)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)",
            "refs/heads", "refs/remotes", "refs/tags",
        ], in: root)
        let mappings = try await RemoteBranchTarget.fetchMappings(in: root)
        let gitHubRemotes: Set<String> = mappings.isEmpty ? [] : await GitHubRepository.fetchRemoteNames(in: root)
        return output.split(separator: 0x0A).compactMap { record in
            let fields = record.split(separator: 0, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard fields.count == 9, fields[5].isEmpty,
                  let kind = RepositoryReference.Kind.allCases.first(where: { fields[0].hasPrefix($0.prefix) })
            else { return nil }

            let commitID = fields[2] == "commit" ? fields[1] : fields[3]
            guard fields[2] == "commit" || fields[4] == "commit" else { return nil }
            let target = kind == .remote ? RemoteBranchTarget.resolve(refID: fields[0], mappings: mappings) : nil
            return RepositoryReference(
                id: fields[0], name: String(fields[0].dropFirst(kind.prefix.count)),
                kind: kind, commitID: commitID, upstreamID: fields[6].isEmpty ? nil : fields[6],
                upstreamTarget: !fields[7].isEmpty && fields[8].hasPrefix("refs/heads/") ? RemoteBranchTarget(remote: fields[7], ref: fields[8]) : nil,
                remoteTarget: target, isGitHubRemote: target.map { gitHubRemotes.contains($0.remote) } ?? false
            )
        }
    }

    private static let commitFormat = "--format=%H%x00%P%x00%an%x00%aI%x00%s%x00%b"

    static func commit(in root: URL, id: String) async throws -> GitCommit {
        let data = try await GitRepository.git(["log", "-1", "--no-notes", "--no-show-signature", "--no-patch", "-z", commitFormat, id, "--"], in: root)
        guard let commit = try parseCommits(data).first, commit.id == id else { throw RepositoryReadError.invalidOutput }
        return commit
    }

    static func commits(in root: URL, maximum: Int = pageSize, query: String? = nil) async throws -> [GitCommit] {
        let output = try await GitRepository.git([
            "log", "--topo-order", "--no-notes", "--no-show-signature", "--no-patch",
            "--max-count=\(maximum)", "-z", commitFormat,
        ] + (query.map { ["--fixed-strings", "--regexp-ignore-case", "--grep=" + $0] } ?? []) + ["--exclude=refs/stash", "--all", "--"], in: root)
        return try parseCommits(output)
    }

    private static func parseCommits(_ output: Data) throws -> [GitCommit] {
        guard !output.isEmpty else { return [] }
        let fields = output.dropLast().split(separator: 0, omittingEmptySubsequences: false)
        guard output.last == 0, fields.count.isMultiple(of: 6) else {
            throw RepositoryReadError.invalidOutput
        }

        let dates = ISO8601DateFormatter()
        func field(_ index: Int) -> String {
            String(decoding: fields[index], as: UTF8.self)
        }
        return stride(from: 0, to: fields.count, by: 6).map { index in
            let subject = field(index + 4)
            return GitCommit(
                id: field(index), parents: field(index + 1).split(separator: " ").map(String.init),
                author: field(index + 2), date: dates.date(from: field(index + 3)),
                subject: subject.isEmpty ? "No commit message" : subject,
                message: field(index + 5).trimmingCharacters(in: .newlines)
            )
        }
    }

    static func allFiles(in root: URL, for commit: GitCommit, changes: [CommitFile]) async throws -> [CommitFile] {
        let data = try await GitRepository.git(["ls-tree", "-r", "-z", "--name-only", commit.id], in: root)
        let changed = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return data.split(separator: 0).map { record in
            let path = String(decoding: record, as: UTF8.self)
            return changed[path] ?? CommitFile(path: path, originalPath: nil, unchanged: true, status: .changed)
        }
    }

    static func files(in root: URL, for commit: GitCommit) async throws -> [CommitFile] {
        try await files(in: root, comparing: TreeComparison(base: commit.parents.first, tip: commit.id))
    }

    static func files(in root: URL, comparing trees: TreeComparison) async throws -> [CommitFile] {
        let options = ["--name-status", "-z", "-M", "--no-ext-diff", "--no-textconv"]
        let output = try await GitRepository.git(trees.arguments(options: options), in: root)
        var fields = output.split(separator: 0).makeIterator()
        var files: [CommitFile] = []

        while let code = fields.next() {
            guard let status = FileChange.Status.parse(code.first), let path = fields.next() else {
                throw RepositoryReadError.invalidOutput
            }
            let name = String(decoding: path, as: UTF8.self)
            if status == .renamed || status == .copied {
                guard let destination = fields.next() else { throw RepositoryReadError.invalidOutput }
                files.append(CommitFile(path: String(decoding: destination, as: UTF8.self),
                                        originalPath: name, status: status))
            } else {
                files.append(CommitFile(path: name, originalPath: nil, status: status))
            }
        }
        return files
    }
}
