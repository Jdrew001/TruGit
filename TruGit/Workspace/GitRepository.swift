import Foundation

struct GitRepository: Equatable, Sendable {
    let root: URL
    let branch: String
    let headID: String?
    let changes: [FileChange]
    let integration: GitIntegration?

    struct Initialization: Identifiable {
        let folder: URL
        let enclosingRepository: URL?
        var id: URL { folder }

        func run() async throws {
            let current = try await GitRepository.enclosingRoot(of: folder)
            if current == folder { return }
            guard current == enclosingRepository else {
                throw RepositoryReadError.commandFailed("The enclosing repository changed. Choose the folder again.")
            }
            _ = try await GitRepository.git(["init", "--", folder.path], in: folder)
        }
    }

    static func enclosingRoot(of folder: URL) async throws -> URL? {
        let root: URL?
        var discoveryError: String?
        do {
            root = try await workingTreeRoot(at: folder, environment: ["LC_ALL": "C"]).resolvingSymlinksInPath()
        } catch RepositoryReadError.commandFailed(let message) where message.hasPrefix("fatal: not a git repository (") {
            discoveryError = message
            root = nil
        }
        if root != folder {
            let marker = folder.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: marker) || (try? FileManager.default.destinationOfSymbolicLink(atPath: marker)) != nil {
                throw RepositoryReadError.commandFailed(discoveryError ?? "This folder already has Git metadata that Git could not read.")
            }
        }
        return root
    }

    private static func workingTreeRoot(at folder: URL, environment: [String: String] = [:]) async throws -> URL {
        let output = try await git(["rev-parse", "--show-toplevel"], in: folder, environment: environment)
        guard output.last == 0x0A, output.count > 1 else { throw RepositoryReadError.invalidOutput }
        return URL(fileURLWithPath: String(decoding: output.dropLast(), as: UTF8.self), isDirectory: true)
    }

    static func read(at folder: URL) async throws -> Self {
        let root = try await workingTreeRoot(at: folder)
        let status = try await git([
            "status", "--porcelain=v2", "--branch", "-z",
            "--untracked-files=all", "--ignore-submodules=none", "--renames",
            "--no-ahead-behind",
        ], in: root)
        let integration = try await GitIntegration.read(in: root)
        return try parseStatus(status, root: root, integration: integration)
    }

    static func git(_ arguments: [String], in folder: URL,
                    accepting exitCodes: Set<Int32> = [0], environment: [String: String] = [:],
                    standardInput: FileHandle = .nullDevice) async throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = folder
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false"] + arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        process.environment?["GIT_NO_LAZY_FETCH"] = "1"
        process.environment?.merge(environment) { _, value in value }
        process.standardInput = standardInput
        process.standardOutput = output
        process.standardError = errors

        let (exitStatuses, exitStatus) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { finished in
            exitStatus.yield(finished.terminationStatus)
            exitStatus.finish()
        }
        do {
            try process.run()
        } catch {
            exitStatus.finish()
            throw error
        }
        async let standardOutput = readPipe(output.fileHandleForReading)
        async let standardError = readPipe(errors.fileHandleForReading)
        var statuses = exitStatuses.makeAsyncIterator()
        guard let status = await statuses.next() else { throw CancellationError() }
        let (data, errorData) = await (standardOutput, standardError)

        guard exitCodes.contains(status) else {
            // Some commands (including merge and commit) explain failures on stdout.
            // Only include readable stdout since plumbing commands also return binary records.
            var messages = [String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)]
            if !data.contains(0), let output = String(data: data, encoding: .utf8) {
                messages.append(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let message = messages.filter { !$0.isEmpty }.joined(separator: "\n")
            throw RepositoryReadError.commandFailed(message.isEmpty ? "Git exited with status \(status)." : message)
        }
        return data
    }

    private static func readPipe(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    private static func parseStatus(_ output: Data, root: URL, integration: GitIntegration?) throws -> Self {
        var branchName: String?
        var commit: String?
        var changes: [FileChange] = []
        var records = output.split(separator: 0).makeIterator()

        while let record = records.next() {
            switch record.first {
            case 0x23: // #
                let header = String(decoding: record, as: UTF8.self)
                if header.hasPrefix("# branch.head ") {
                    branchName = String(header.dropFirst("# branch.head ".count))
                } else if header.hasPrefix("# branch.oid ") {
                    commit = String(header.dropFirst("# branch.oid ".count))
                }
            case 0x31: // 1
                changes.append(try FileChange(record: record, pathField: 8))
            case 0x32: // 2
                guard let originalPath = records.next() else {
                    throw RepositoryReadError.invalidOutput
                }
                changes.append(try FileChange(record: record, pathField: 9, originalPath: originalPath))
            case 0x75: // u
                changes.append(try FileChange(record: record, pathField: 10, conflict: true))
            case 0x3F: // ?
                changes.append(FileChange(path: record.dropFirst(2), staged: nil, workingTree: .untracked))
            default:
                throw RepositoryReadError.invalidOutput
            }
        }

        guard let branchName else {
            throw RepositoryReadError.invalidOutput
        }
        let branch = branchName == "(detached)"
            ? "Detached HEAD" + (commit.map { " · \($0.prefix(7))" } ?? "")
            : branchName
        return Self(root: root, branch: branch, headID: commit == "(initial)" ? nil : commit,
                    changes: changes, integration: integration)
    }
}

struct FileChange: Identifiable, Equatable, Sendable {
    struct ID: Hashable {
        let path: Data
        let isUntracked: Bool
    }

    let id: ID
    let path: String
    let originalPath: String?
    let staged: Status?
    let workingTree: Status?

    enum Status: String, Sendable {
        case modified = "Modified"
        case typeChanged = "Type changed"
        case added = "Added"
        case deleted = "Deleted"
        case renamed = "Renamed"
        case copied = "Copied"
        case untracked = "Untracked"
        case conflict = "Conflict"
        case changed = "Changed"

        static func parse(_ code: UInt8?) -> Self? {
            guard let code else { return nil }
            switch UnicodeScalar(code) {
            case ".": return nil
            case "M": return .modified
            case "T": return .typeChanged
            case "A": return .added
            case "D": return .deleted
            case "R": return .renamed
            case "C": return .copied
            default: return .changed
            }
        }
    }

    init(path: Data, originalPath: Data? = nil, staged: Status?, workingTree: Status?) {
        id = ID(path: path, isUntracked: workingTree == .untracked)
        self.path = String(decoding: path, as: UTF8.self)
        self.originalPath = originalPath.map { String(decoding: $0, as: UTF8.self) }
        self.staged = staged
        self.workingTree = workingTree
    }

    init(record: Data, pathField: Int, originalPath: Data? = nil, conflict: Bool = false) throws {
        let fields = record.split(separator: 0x20, maxSplits: pathField, omittingEmptySubsequences: false)
        guard fields.count == pathField + 1, fields[1].count == 2 else {
            throw RepositoryReadError.invalidOutput
        }
        self.init(
            path: fields[pathField],
            originalPath: originalPath,
            staged: conflict ? .conflict : Status.parse(fields[1].first),
            workingTree: conflict ? .conflict : Status.parse(fields[1].last)
        )
    }
}

enum RepositoryReadError: LocalizedError {
    case commandFailed(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            message.isEmpty ? "Git could not read the selected folder." : message
        case .invalidOutput:
            "Git returned unexpected repository data."
        }
    }
}
