import Foundation

struct GitHubFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class NoGitHubRedirect: NSObject, URLSessionTaskDelegate {
    static let shared = NoGitHubRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct GitHubAPI: Sendable {
    private let token: String
    private let session: URLSession

    init(token: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.token = token
        self.session = session
    }

    private func request(_ path: [String], query: [URLQueryItem] = [], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let base = URL(string: "https://api.github.com")!
        let url = path.reduce(base) { $0.appendingPathComponent($1) }.appending(queryItems: query)
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request, delegate: NoGitHubRedirect.shared)
        guard let http = response as? HTTPURLResponse else { throw GitHubFailure("Invalid GitHub response.") }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            var message = json?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            if let errors = json?["errors"] as? [[String: Any]] {
                let details = errors.compactMap { $0["message"] as? String }.joined(separator: "\n")
                if !details.isEmpty { message += "\n" + details }
            }
            if http.statusCode == 401 { message += "\nReconnect your account in GitHub settings." }
            if [403, 404].contains(http.statusCode) { message += "\nCheck the token’s repository access and organization approval." }
            throw GitHubFailure("GitHub returned \(http.statusCode). " + message.replacingOccurrences(of: token, with: "••••"))
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func all<T: Decodable>(_ path: [String]) async throws -> [T] {
        var result: [T] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let (data, response) = try await request(path, query: [.init(name: "per_page", value: "100"), .init(name: "page", value: String(page))])
            let items: [T] = try decode(data)
            result.append(contentsOf: items)
            guard !items.isEmpty, response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true else { return result }
            page += 1
        }
    }

    func user() async throws -> GitHubUser { try decode(await request(["user"]).0) }

    struct Page { let items: [GitHubPull]; let more: Bool }
    func pulls(_ repo: GitHubRepository, state: String, page: Int) async throws -> Page {
        let (data, response) = try await request(repo.endpoint + ["pulls"], query: [
            .init(name: "state", value: state), .init(name: "sort", value: "updated"), .init(name: "page", value: String(page))
        ])
        return try Page(items: decode(data), more: response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true)
    }

    func pull(_ repo: GitHubRepository, _ number: Int) async throws -> GitHubPull {
        try decode(await request(repo.endpoint + ["pulls", String(number)]).0)
    }

    func activity(_ repo: GitHubRepository, _ number: Int) async throws -> [PullActivity] {
        let path = repo.endpoint + ["pulls", String(number)]
        async let conversation: [PullActivity] = all(repo.endpoint + ["issues", String(number), "comments"])
        async let reviews: [PullActivity] = all(path + ["reviews"])
        async let inline: [PullActivity] = all(path + ["comments"])
        let entries = try await conversation + reviews + inline
        return entries.sorted { ($0.submittedAt ?? $0.createdAt ?? .distantPast, $0.id) < ($1.submittedAt ?? $1.createdAt ?? .distantPast, $1.id) }
    }

    func files(_ repo: GitHubRepository, _ number: Int) async throws -> [PullFile] {
        try await all(repo.endpoint + ["pulls", String(number), "files"])
    }

    func defaultBranch(_ repo: GitHubRepository) async throws -> String {
        struct Info: Decodable { let defaultBranch: String }
        let info: Info = try decode(await request(repo.endpoint).0)
        return info.defaultBranch
    }

    func branches(_ repo: GitHubRepository) async throws -> [String] {
        struct Branch: Decodable { let name: String }
        let branches: [Branch] = try await all(repo.endpoint + ["branches"])
        return branches.map(\.name)
    }

    func create(in baseRepo: GitHubRepository, base: String, from headRepo: GitHubRepository, head: String,
                title: String, body: String) async throws -> GitHubPull {
        var fields = ["base": base, "head": head, "title": title, "body": body]
        if baseRepo != headRepo {
            fields["head"] = headRepo.owner + ":" + head
            fields["head_repo"] = headRepo.name
        }
        return try decode(await request(baseRepo.endpoint + ["pulls"], body: JSONEncoder().encode(fields)).0)
    }

    func comment(_ body: String, repo: GitHubRepository, number: Int, replyingTo: Int? = nil) async throws {
        let path = replyingTo.map { ["pulls", String(number), "comments", String($0), "replies"] }
            ?? ["issues", String(number), "comments"]
        _ = try await request(repo.endpoint + path, body: JSONEncoder().encode(["body": body]))
    }

    func review(_ decision: ReviewDecision, body: String, repo: GitHubRepository, pull: GitHubPull) async throws {
        let latest = try await self.pull(repo, pull.number)
        guard latest.state == "open", latest.head.sha == pull.head.sha, latest.base.sha == pull.base.sha else {
            throw GitHubFailure("The pull request changed. Refresh and review the latest changes before submitting.")
        }
        let fields = ["event": decision.rawValue, "body": body, "commit_id": pull.head.sha]
        _ = try await request(repo.endpoint + ["pulls", String(pull.number), "reviews"], body: JSONEncoder().encode(fields))
    }
}
