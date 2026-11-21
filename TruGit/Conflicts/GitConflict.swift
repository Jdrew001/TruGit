import Foundation

enum ConflictChoice: String, CaseIterable, Sendable {
    case left = "Left", right = "Right", both = "Both"
}

struct ConflictHunk: Identifiable, Sendable {
    let id: Int
    let range: Range<Int>
    let line: Int
    let left: Data
    let right: Data

    func content(for choice: ConflictChoice) -> Data {
        switch choice {
        case .left: left
        case .right: right
        case .both: left + right
        }
    }
}

// Keep the original byte ranges so untouched lines, whitespace and CRLF survive a resolution.
struct ConflictText: Sendable {
    let data: Data
    let hunks: [ConflictHunk]

    init(data: Data, markerSize: Int) throws {
        self.data = data
        var hunks: [ConflictHunk] = []
        var cursor = 0
        var line = 1
        var opening: (offset: Int, content: Int, line: Int)?
        var baseStart: Int?
        var separator: (offset: Int, content: Int)?
        while cursor < data.count {
            let end = data[cursor...].firstIndex(of: 10).map { $0 + 1 } ?? data.count
            let start = cursor
            defer { cursor = end; line += 1 }
            let char = data[start]
            guard [60, 124, 61, 62].contains(char) else { continue }
            let count = data[start..<end].prefix(while: { $0 == char }).count
            guard count == markerSize else { continue }
            let suffix = data[(start + count)..<end]
            let hasLabel = suffix.first == 32 || suffix.first == 9
            let atEnd = suffix.isEmpty || suffix.elementsEqual([10]) || suffix.elementsEqual([13, 10])
            guard atEnd || (char != 61 && hasLabel) else { continue }
            switch char {
            case 60:
                guard opening == nil else { throw ConflictError.markers }
                opening = (start, end, line)
            case 124 where opening != nil:
                guard baseStart == nil, separator == nil else { throw ConflictError.markers }
                baseStart = start
            case 61 where opening != nil:
                guard separator == nil else { throw ConflictError.markers }
                separator = (start, end)
            case 62:
                guard let block = opening, let split = separator else { throw ConflictError.markers }
                hunks.append(.init(id: hunks.count, range: block.offset..<end, line: block.line,
                                   left: data.subdata(in: block.content..<(baseStart ?? split.offset)),
                                   right: data.subdata(in: split.content..<start)))
                opening = nil
                baseStart = nil
                separator = nil
            default: break
            }
        }
        guard opening == nil else { throw ConflictError.markers }
        self.hunks = hunks
    }

    enum ResultPart {
        case context(Data)
        case conflict(id: Int, content: Data?)
    }

    func resultParts(using choices: [Int: ConflictChoice]) -> [ResultPart] {
        var parts: [ResultPart] = []
        var offset = 0
        for hunk in hunks {
            if offset < hunk.range.lowerBound {
                parts.append(.context(data[offset..<hunk.range.lowerBound]))
            }
            parts.append(.conflict(id: hunk.id, content: choices[hunk.id].map(hunk.content)))
            offset = hunk.range.upperBound
        }
        if offset < data.endIndex { parts.append(.context(data[offset...])) }
        return parts
    }

    func resolved(using choices: [Int: ConflictChoice]) throws -> Data {
        var result = Data()
        for part in resultParts(using: choices) {
            switch part {
            case .context(let data), .conflict(_, .some(let data)): result.append(data)
            case .conflict(_, nil): throw ConflictError.incomplete
            }
        }
        return result
    }
}

enum ConflictResolution: Sendable {
    case hunks([Int: ConflictChoice])
    case edited(Data, side: ConflictChoice?)
    case side(ConflictChoice)
    case workingCopy
}

struct GitConflict: Sendable {
    struct Side: Sendable {
        let mode: String
        let oid: String
        var isSubmodule: Bool { mode == "160000" }
    }

    private enum FileState: Equatable, Sendable {
        case regular(Data, Int)
        case link(String)
        case missing
    }

    let path: String
    let text: ConflictText?
    let left: Side?
    let right: Side?
    private let index: Data
    private let state: FileState

    private static func indexEntries(_ path: String, in root: URL) async throws -> Data {
        try await GitRepository.git(["--literal-pathspecs", "ls-files", "-u", "-z", "--", path], in: root)
    }

    private static func fileState(at url: URL) throws -> FileState {
        let manager = FileManager.default
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try manager.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .missing
        }
        switch attrs[.type] as? FileAttributeType {
        case .typeRegular:
            return .regular(try Data(contentsOf: url), (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644)
        case .typeSymbolicLink:
            return .link(try manager.destinationOfSymbolicLink(atPath: url.path))
        default: throw ConflictError.special
        }
    }

    static func read(path: String, in root: URL) async throws -> Self {
        let index = try await indexEntries(path, in: root)
        guard !index.isEmpty else { throw ConflictError.stale }
        var sides: [String: Side] = [:]
        for record in index.split(separator: 0) {
            let fields = record.prefix(while: { $0 != 9 }).split(separator: 32)
            guard fields.count == 3 else { throw RepositoryReadError.invalidOutput }
            sides[String(decoding: fields[2], as: UTF8.self)] =
                Side(mode: String(decoding: fields[0], as: UTF8.self), oid: String(decoding: fields[1], as: UTF8.self))
        }
        guard !sides.values.contains(where: \.isSubmodule) else { throw ConflictError.special }
        let state = try fileState(at: root.appendingPathComponent(path))
        var text: ConflictText?
        if case .regular(let data, _) = state, !data.contains(0), String(data: data, encoding: .utf8) != nil {
            let attr = try await GitRepository.git(["check-attr", "-z", "conflict-marker-size", "--", path], in: root)
            let size = attr.split(separator: 0).last.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 7
            text = try ConflictText(data: data, markerSize: size > 0 ? size : 7)
        }
        return Self(path: path, text: text, left: sides["2"], right: sides["3"], index: index, state: state)
    }

    func hasSameInputs(as other: Self) -> Bool {
        path == other.path && index == other.index && state == other.state
    }

    func apply(_ resolution: ConflictResolution, in root: URL) async throws {
        let url = root.appendingPathComponent(path)
        guard try await Self.indexEntries(path, in: root) == index,
              try Self.fileState(at: url) == state else { throw ConflictError.stale }

        switch resolution {
        case .hunks(let choices):
            guard case .regular(_, let mode) = state, let text, !text.hunks.isEmpty else { throw ConflictError.incomplete }
            let resolved = try text.resolved(using: choices)
            try write(resolved, mode: mode, to: url)
        case .edited(let bytes, let choice):
            let mode: Int
            if let choice {
                let side = choice == .left ? left : right
                guard choice != .both, let side, ["100644", "100755"].contains(side.mode) else { throw ConflictError.special }
                mode = side.mode == "100755" ? 0o755 : 0o644
            } else {
                guard case .regular(_, let currentMode) = state, text != nil else { throw ConflictError.special }
                mode = currentMode
            }
            try write(bytes, mode: mode, to: url)
        case .side(let choice):
            guard choice != .both else { throw ConflictError.incomplete }
            if (choice == .left ? left : right) == nil {
                _ = try await GitRepository.git(["--literal-pathspecs", "rm", "-f", "--", path], in: root)
                return
            }
            _ = try await GitRepository.git(["--literal-pathspecs", "checkout", choice == .left ? "--ours" : "--theirs", "--", path], in: root)
        case .workingCopy:
            guard text?.hunks.isEmpty != false else { throw ConflictError.incomplete }
        }
        _ = try await GitRepository.git(["--literal-pathspecs", "add", "--all", "--", path], in: root)
    }

    private func write(_ resolved: Data, mode: Int, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".trugit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try resolved.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

enum ConflictError: LocalizedError {
    case stale, incomplete, markers, special

    var errorDescription: String? {
        switch self {
        case .stale: "The working file or Git index changed. Reopen the file to review its current contents."
        case .incomplete: "Choose a resolution for each conflict before saving."
        case .markers: "The conflict markers are incomplete or nested. Repair them in the working file, then refresh."
        case .special: "Resolve this directory or submodule in the repository, then refresh."
        }
    }
}

