import Foundation

struct RepositoryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try git("init", "-q", "-b", "main")
            try git("config", "core.hooksPath", "/dev/null")
            try git("config", "user.name", "E2E")
            try git("config", "user.email", "e2e@example.invalid")
            try git("config", "commit.gpgsign", "false")
            try git("config", "tag.gpgsign", "false")
            try git("commit", "--allow-empty", "-qm", "Baseline")
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func write(_ name: String, _ content: String) throws {
        try content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try runGit(arguments)
    }

    func runGit(_ arguments: [String]) throws -> String {
        let task = Process()
        // /usr/bin/git delegates to xcrun, which cannot run inside the XCTest runner sandbox.
        guard let path = Bundle(for: TruGitUITestCase.self).object(forInfoDictionaryKey: "FixtureGitPath") as? String else {
            throw CocoaError(.fileNoSuchFile)
        }
        task.executableURL = URL(fileURLWithPath: path)
        task.currentDirectoryURL = root
        task.arguments = ["-c", "user.name=E2E", "-c", "user.email=e2e@example.invalid"] + arguments
        task.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "GitFixture", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
