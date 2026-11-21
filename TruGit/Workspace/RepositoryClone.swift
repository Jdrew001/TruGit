import Foundation
import Darwin

struct RepositoryClone {
    let source: String
    let parent: URL
    let folderName: String

    static func suggestedName(for source: String) -> String {
        let location = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = location.contains("://") ? URLComponents(string: location)?.path : location
        guard let path, let last = path.split(separator: "/").last else { return "" }
        let name = !path.contains("/") && !location.contains("://") ? String(last.split(separator: ":").last ?? last) : String(last)
        return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    func run() async throws -> URL {
        let location = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty, !location.contains("\0") else {
            throw RepositoryReadError.commandFailed("Enter a repository URL.")
        }
        guard !name.isEmpty, ![".", "..", ".git"].contains(name.lowercased()), !name.contains("/"), !name.contains("\0") else {
            throw RepositoryReadError.commandFailed("Enter a single folder name for the clone.")
        }
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else {
            throw RepositoryReadError.commandFailed("A file or folder already exists at " + destination.path + ". Choose a different name or location.")
        }
        // Use a private sibling until Git finishes. Publish with an exclusive rename
        // so another clone or folder created during the fetch cannot be overwritten.
        let staging = parent.appendingPathComponent(".trugit-clone-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let checkout = staging.appendingPathComponent("checkout", isDirectory: true)
        _ = try await GitRepository.git(["clone", "--", location, checkout.path], in: parent,
            environment: ["GIT_ALLOW_PROTOCOL": "https:http:ssh:git:file", "GIT_TERMINAL_PROMPT": "0"])
        guard renamex_np(checkout.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
        return destination
    }
}
