#if TRUGIT_E2E
import Foundation

/// Compiled only into the E2E app. Unknown requests fail locally.
final class GitHubFixtureProtocol: URLProtocol {
    static func api() -> GitHubAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubFixtureProtocol.self]
        return GitHubAPI(token: "fixture", session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url, url.host == "api.github.com",
                  let fixture = ProcessInfo.processInfo.environment["TRUGIT_PULL_FIXTURE"] else {
                throw URLError(.unsupportedURL)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
            guard let responses = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pull = responses["pull"], let files = responses["files"] else { throw URLError(.cannotParseResponse) }
            let route = url.path
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let page = query.first { $0.name == "page" }?.value ?? "1"
            let state = query.first { $0.name == "state" }?.value ?? ""
            let pageKey = [route, state, page].joined(separator: "|")
            let pages = responses["pages"] as? [String: [String: Any]]
            var status = 200
            var headers: [String: String] = [:]
            let payload: Any
            if request.httpMethod == "POST" {
                guard let ledger = ProcessInfo.processInfo.environment["TRUGIT_REQUEST_LOG"],
                      let writes = responses["writes"] as? [String: Any], let result = writes[route] else {
                    throw URLError(.unsupportedURL)
                }
                let fields = try JSONSerialization.jsonObject(with: try bodyData())
                let receipt: [String: Any] = ["path": route, "fields": fields]
                try JSONSerialization.data(withJSONObject: receipt).write(to: URL(fileURLWithPath: ledger), options: .atomic)
                payload = result
            } else if let response = pages?[pageKey], let body = response["body"] {
                status = response["status"] as? Int ?? 200
                headers = response["headers"] as? [String: String] ?? [:]
                payload = body
            } else if let routes = responses["routes"] as? [String: Any], let result = routes[route] {
                payload = result
            } else {
                switch route {
                case "/repos/example/review/pulls":
                    payload = state == "closed" ? [] : [pull]
                case "/repos/example/review/pulls/42": payload = pull
                case "/repos/example/review/pulls/42/files": payload = files
                default: throw URLError(.resourceUnavailable)
                }
            }
            let body = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func bodyData() throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw URLError(.zeroByteResource) }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
        }
    }

    override func stopLoading() {}

}
#endif
