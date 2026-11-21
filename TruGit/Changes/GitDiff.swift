import Foundation

struct DiffRequest: Identifiable, Sendable {
    enum Source: Hashable, Sendable {
        case staged
        case workingTree(FileChange.Status)
        case commit(GitCommit)
        case unchanged(GitCommit)
        case stash(StashPart)

        var title: String {
            switch self {
            case .stash(let part): part.kind.rawValue
            case .staged: "Staged"
            case .workingTree: "Unstaged"
            case .commit: "Commit"
            case .unchanged: "File at Commit"
            }
        }

        var labels: (before: String, after: String) {
            switch self {
            case .stash(let part):
                switch part.kind {
                case .staged: ("Stash base", "Stashed index")
                case .unstaged: ("Stashed index", "Stashed working tree")
                case .untracked: ("Empty file", "Stashed untracked file")
                }
            case .staged:
                ("HEAD", "Index")
            case .workingTree(.untracked):
                ("Empty file", "Working Tree")
            case .workingTree(.conflict):
                ("Ours", "Working Tree")
            case .workingTree:
                ("Index", "Working Tree")
            case .unchanged(let commit), .commit(let commit):
                (commit.parents.first.map { "Parent \($0.prefix(7))" } ?? "Empty tree", "Commit \(commit.shortID)")
            }
        }
    }

    let id = UUID()
    let root: URL
    let path: String
    let originalPath: String?
    let source: Source
}

struct DiffSelection: Sendable {
    let request: DiffRequest
    let sources: [DiffRequest.Source]
}

struct GitDiff: Sendable {
    struct Line: Sendable {
        enum Change: Sendable {
            case context, removed, added
        }
        let number: Int
        let text: String
        let change: Change
    }

    struct Row: Identifiable, Sendable {
        enum Content: Sendable {
            case hunk(String)
            case lines(before: Line?, after: Line?)
        }
        let id: Int
        let content: Content
    }

    let rows: [Row]
    let isBinary: Bool

    static func read(_ request: DiffRequest) async throws -> Self {
        let options = [
            "--no-color", "--no-ext-diff", "--no-textconv", "--unified=3",
            "--submodule=short", "-M",
        ]
        let paths = ["--"] + [request.originalPath, request.path].compactMap { $0 }
        let data: Data
        switch request.source {
        case .staged:
            data = try await GitRepository.git(["--literal-pathspecs", "diff", "--cached"] + options + paths,
                                               in: request.root)
        case .workingTree(.untracked):
            data = try await GitRepository.git(["diff", "--no-index"] + options + ["--", "/dev/null", request.path],
                                               in: request.root, accepting: [0, 1])
        case .workingTree(let status):
            let stage = status == .conflict ? ["--ours"] : []
            data = try await GitRepository.git(["--literal-pathspecs", "diff"] + stage + options + paths,
                                               in: request.root)
        case .unchanged(let commit):
            let object = commit.id + ":" + request.path
            let kind = try await GitRepository.git(["cat-file", "-t", object], in: request.root)
            guard kind == Data("blob\n".utf8) else { return GitDiff(rows: [], isBinary: true) }
            let bytes = try await GitRepository.git(["cat-file", "blob", object], in: request.root)
            guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else { return GitDiff(rows: [], isBinary: true) }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last?.isEmpty == true { lines.removeLast() }
            return GitDiff(rows: lines.enumerated().map { index, value in
                let line = Line(number: index + 1, text: String(value), change: .context)
                return Row(id: index, content: .lines(before: line, after: line))
            }, isBinary: false)
        case .commit(let commit):
            let trees = TreeComparison(base: commit.parents.first, tip: commit.id)
            data = try await GitRepository.git(["--literal-pathspecs"] + trees.arguments(options: options + ["-p"], paths: Array(paths.dropFirst())), in: request.root)
        case .stash(let part):
            data = try await GitRepository.git(["--literal-pathspecs"] + part.trees.arguments(options: options + ["-p"], paths: Array(paths.dropFirst())), in: request.root)
        }

        var parser = PatchParser()
        return parser.parse(data)
    }
}

private struct PatchParser {
    private var rows: [GitDiff.Row] = []
    private var removed: [GitDiff.Line] = []
    private var added: [GitDiff.Line] = []
    private var before = 0
    private var after = 0
    private var insideHunk = false
    private var isBinary = false
    private var hasMissingNewline = false

    mutating func parse(_ data: Data) -> GitDiff {
        for line in data.split(separator: 0x0A) {
            consume(String(decoding: line, as: UTF8.self))
        }
        flushChanges()
        return GitDiff(rows: rows, isBinary: isBinary)
    }

    private mutating func consume(_ line: String) {
        if line.hasPrefix("@@ ") {
            startHunk(line)
        } else if line.hasPrefix("diff --git ") {
            flushChanges()
            insideHunk = false
        } else if insideHunk {
            addLine(line)
        } else if line.hasPrefix("Binary files ") {
            isBinary = true
        }
    }

    private mutating func startHunk(_ header: String) {
        flushChanges()
        let parts = header.split(separator: " ", maxSplits: 3)
        guard parts.count >= 3,
              let oldStart = Int(parts[1].dropFirst().prefix(while: \.isNumber)),
              let newStart = Int(parts[2].dropFirst().prefix(while: \.isNumber))
        else {
            insideHunk = false
            return
        }

        before = oldStart
        after = newStart
        insideHunk = true
        append(.hunk(header))
    }

    private mutating func addLine(_ line: String) {
        let text = String(line.dropFirst())
        switch line.first {
        case "-":
            removed.append(.init(number: before, text: text, change: .removed))
            before += 1
        case "+":
            added.append(.init(number: after, text: text, change: .added))
            after += 1
        case " ":
            flushChanges()
            append(.lines(before: .init(number: before, text: text, change: .context),
                          after: .init(number: after, text: text, change: .context)))
            before += 1
            after += 1
        case "\\":
            hasMissingNewline = true
        default:
            break
        }
    }

    private mutating func flushChanges() {
        for index in 0..<max(removed.count, added.count) {
            append(.lines(before: index < removed.count ? removed[index] : nil,
                          after: index < added.count ? added[index] : nil))
        }
        removed.removeAll(keepingCapacity: true)
        added.removeAll(keepingCapacity: true)
        if hasMissingNewline {
            append(.hunk("No newline at end of file"))
            hasMissingNewline = false
        }
    }

    private mutating func append(_ content: GitDiff.Row.Content) {
        rows.append(.init(id: rows.count, content: content))
    }
}
