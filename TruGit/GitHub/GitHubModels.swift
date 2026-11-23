import Foundation

struct GitHubRepository: Hashable, Identifiable, Sendable {
    let owner: String
    let name: String
    var id: String { owner + "/" + name }
    var endpoint: [String] { ["repos", owner, name] }

    init?(remoteURL: String) {
        let value = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let url = URLComponents(string: value), url.host?.lowercased() == "github.com",
           ["https", "http", "ssh", "git"].contains(url.scheme?.lowercased() ?? "") {
            path = url.path
        } else if value.lowercased().hasPrefix("git@github.com:") {
            path = String(value.dropFirst("git@github.com:".count))
        } else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let valid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard [parts[0], repo].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(valid.contains) }) else { return nil }
        owner = parts[0]
        name = repo
    }

    static func destinations(in root: URL, remotes: [String]) async throws -> [Self] {
        var result: [Self] = []
        for remote in remotes {
            let data = try await GitRepository.git(["remote", "get-url", "--", remote], in: root)
            if let repo = Self(remoteURL: String(decoding: data, as: UTF8.self)), !result.contains(repo) {
                if remote == "origin" { result.insert(repo, at: 0) } else { result.append(repo) }
            }
        }
        return result
    }

    static func fetchRemoteNames(in root: URL) async -> Set<String> {
        guard let listing = try? await GitRepository.git(["remote", "-v"], in: root) else { return [] }
        let lines = String(decoding: listing, as: UTF8.self).split(separator: "\n")
        return Set(lines.compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { return nil }
            let details = fields[1].split(separator: " ", maxSplits: 2)
            guard details.count >= 2, details[1] == "(fetch)", Self(remoteURL: String(details[0])) != nil else { return nil }
            return String(fields[0])
        })
    }
}

struct GitHubUser: Decodable, Sendable { let login: String }

enum PullRequestStatus: String {
    case open = "Open", draft = "Draft", closed = "Closed", merged = "Merged"

    init(state: String, draft: Bool?, mergedAt: String?) {
        if mergedAt != nil { self = .merged }
        else if state == "closed" { self = .closed }
        else { self = draft == true ? .draft : .open }
    }
}

enum PullRequestOrder: String, CaseIterable, Equatable {
    case updated, created

    var title: String { self == .updated ? "Recently updated" : "Newest opened" }
    var dateHeading: String { self == .updated ? "Updated" : "Opened" }
}

struct PullRequestSummary: Decodable, Identifiable, Sendable {
    // Search responses include the merge date in their pull_request object.
    struct SearchMetadata: Decodable, Sendable { let mergedAt: String? }

    let number: Int
    let title: String
    let user: GitHubUser?
    let createdAt: Date?
    let updatedAt: Date?
    let state: String
    let draft: Bool?
    let mergedAt: String?
    let pullRequest: SearchMetadata?

    var id: Int { number }
    var status: PullRequestStatus { .init(state: state, draft: draft, mergedAt: mergedAt ?? pullRequest?.mergedAt) }
    var author: String { user?.login ?? "Unknown author" }

    func date(for order: PullRequestOrder) -> Date? { order == .updated ? updatedAt : createdAt }
}

struct GitHubPull: Decodable, Identifiable, Sendable {
    struct Branch: Decodable, Sendable { let label: String; let sha: String }
    let number: Int
    let title: String
    let body: String?
    let user: GitHubUser?
    let head: Branch
    let base: Branch
    let state: String
    let draft: Bool?
    let mergedAt: String?
    let createdAt: Date?
    var id: Int { number }
    var status: PullRequestStatus { .init(state: state, draft: draft, mergedAt: mergedAt) }
}

struct PullActivity: Decodable, Identifiable, Sendable {
    let id: Int
    let user: GitHubUser?
    let body: String?
    let state: String?
    let path: String?
    let line: Int?
    let inReplyToId: Int?
    let originalLine: Int?
    let diffHunk: String?
    let createdAt: Date?
    let submittedAt: Date?
    var key: String {
        let kind = path != nil ? "inline" : state == nil ? "comment" : "review"
        return "\(kind)-\(id)"
    }
    var title: String {
        switch state {
        case "APPROVED": "approved"
        case "CHANGES_REQUESTED": "requested changes"
        case "DISMISSED": "review dismissed"
        case "COMMENTED": "reviewed"
        default: path == nil ? "commented" : "commented on code"
        }
    }
}

struct PullConversation: Sendable {
    struct Thread: Identifiable, Sendable {
        let entry: PullActivity
        let replies: [PullActivity]
        var id: String { entry.key }
    }

    let threads: [Thread]

    nonisolated static func build(from activity: [PullActivity]) async -> Self {
        var seen = Set<String>()
        let unique = activity.filter { seen.insert($0.key).inserted }
        let inlineRoots = Set(unique.filter { $0.path != nil && $0.inReplyToId == nil }.map(\.id))
        var replies: [Int: [PullActivity]] = [:]
        var roots: [PullActivity] = []
        for entry in unique {
            if let parent = entry.inReplyToId, inlineRoots.contains(parent) {
                replies[parent, default: []].append(entry)
            } else {
                roots.append(entry)
            }
        }
        return Self(threads: roots.map { entry in
            Thread(entry: entry, replies: entry.path == nil ? [] : replies[entry.id] ?? [])
        })
    }
}

struct PullFile: Decodable, Identifiable, Sendable {
    let filename: String
    let sha: String
    let status: String
    let previousFilename: String?
    let additions: Int
    let deletions: Int
    let patch: String?
    var id: String { filename }
}

enum ReviewDecision: String, CaseIterable {
    case comment = "COMMENT", approve = "APPROVE", changes = "REQUEST_CHANGES"
    var title: String {
        switch self {
        case .comment: "Comment"
        case .approve: "Approve"
        case .changes: "Request changes"
        }
    }
}
