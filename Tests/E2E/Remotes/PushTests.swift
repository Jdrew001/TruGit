import XCTest

final class PushTests: TruGitUITestCase {
    func testFirstPushPublishesBranchAndShowsSuccess() throws {
        let remote = repository.root.appendingPathComponent(".git/test-remote.git")
        try repository.git("init", "--bare", remote.path)
        try repository.git("remote", "add", "origin", remote.path)
        launch()

        clickVisible(app.buttons["Push"])
        expectSuccess("Published main to origin")
        XCTAssertEqual(try repository.git("--git-dir", remote.path, "rev-parse", "refs/heads/main"),
                       try repository.git("rev-parse", "HEAD"))
    }

    private func trackedRemote() throws -> URL {
        let remote = repository.root.appendingPathComponent(".git/remote.git")
        try repository.git("init", "--bare", "-b", "main", remote.path)
        try repository.git("remote", "add", "origin", remote.path)
        try repository.git("push", "-u", "origin", "main")
        return remote
    }

    func testFetchAndPullAdvanceTrackingThenCheckedOutBranch() throws {
        let remote = try trackedRemote()
        let clone = repository.root.appendingPathComponent(".git/peer").path
        try repository.git("clone", remote.path, clone)
        launch()
        expectFetchStatus("Remotes fetched")
        try repository.git("-C", clone, "commit", "--allow-empty", "-m", "Incoming change")
        try repository.git("-C", clone, "push")
        let incoming = try repository.git("-C", clone, "rev-parse", "HEAD")
        let old = try repository.git("rev-parse", "HEAD")
        app.menuButtons["Actions"].click()
        app.menuItems["Fetch All Remotes"].click()
        expectSuccess("Fetch succeeded")
        expectGit(incoming, ["rev-parse", "origin/main"])
        XCTAssertEqual(try repository.git("rev-parse", "HEAD"), old)
        clickVisible(app.buttons["Pull"])
        expectSuccess("Pulled changes into main")
        expectGit(incoming, ["rev-parse", "HEAD"])
    }

    func testOpeningRepositoryFetchesWithoutBlockingWorkspace() throws {
        let remote = try trackedRemote()
        let gitFolder = remote.deletingLastPathComponent()
        let peer = gitFolder.appendingPathComponent("peer").path
        try repository.git("clone", remote.path, peer)
        try repository.git("-C", peer, "commit", "--allow-empty", "-m", "Background arrival")
        try repository.git("-C", peer, "push")
        let incoming = try repository.git("-C", peer, "rev-parse", "HEAD")
        let old = try repository.git("rev-parse", "HEAD")
        try repository.write("notes.txt", "Work in progress")
        let changes = try repository.git("status", "--porcelain")

        let release = gitFolder.appendingPathComponent("allow-fetch")
        let delay = """
        for attempt in $(seq 1 150); do
            if test -f "$1/../allow-fetch"; then exec /usr/bin/git-upload-pack "$@"; fi
            sleep 0.2
        done
        exit 1
        """
        try repository.git("config", "remote.origin.uploadpack", "/bin/sh -c '\(delay)' upload-pack")

        launch()
        expectFetchStatus("Fetching remotes…")
        XCTAssertEqual(try repository.git("rev-parse", "origin/main"), old)
        clickVisible(app.buttons["Search"])
        XCTAssertTrue(app.textFields["Search commit messages on all branches"].exists)
        app.typeKey(.escape, modifierFlags: [])
        clickVisible(app.buttons["notes.txt, Untracked"])
        expectText("Work in progress")

        try Data().write(to: release)
        expectFetchStatus("Remotes fetched")
        expectGit(incoming, ["rev-parse", "origin/main"])
        XCTAssertTrue(app.buttons["Back to changed files"].exists)
        expectText("Work in progress")
        XCTAssertEqual(try repository.git("rev-parse", "HEAD"), old)
        XCTAssertEqual(try repository.git("status", "--porcelain"), changes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitFolder.appendingPathComponent("FETCH_HEAD").path))
    }

    private func expectFetchStatus(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let status = app.descendants(matching: .any).matching(identifier: "repository-fetch-status")
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), "Missing fetch status: " + text, file: file, line: line)
    }

    func testCombinedCommitCanSetUpItsFirstRemote() throws {
        let remote = repository.root.appendingPathComponent(".git/destination.git")
        try repository.git("init", "--bare", remote.path)
        try repository.write("new.txt", "publish")
        try repository.git("add", "new.txt")
        app.launchArguments += ["-commitButtonAction", "commitAndPush"]
        launch()
        enter("First publication", in: app.textFields["Commit summary"])
        clickVisible(app.buttons["Commit and Push"])
        let submit = app.sheets.buttons["Commit and Push"]
        XCTAssertFalse(submit.isEnabled)
        enter(remote.path, in: app.textFields["Repository URL or absolute path"])
        clickVisible(submit)
        expectSuccess("Committed and pushed changes")
        expectGit("First publication", ["log", "-1", "--format=%s"])
        XCTAssertEqual(try repository.git("remote", "get-url", "origin"), remote.path)
        XCTAssertEqual(try repository.git("--git-dir", remote.path, "show", "main:new.txt"), "publish")
    }

    func testCombinedCommitRetryPushesTheSameCommit() throws {
        let remote = try trackedRemote()
        let offline = remote.deletingLastPathComponent().appendingPathComponent("offline.git")
        try FileManager.default.moveItem(at: remote, to: offline)
        try repository.write("notes.txt", "outgoing")
        try repository.git("add", ".")
        app.launchArguments += ["-commitButtonAction", "commitAndPush"]
        launch()
        enter("Locally committed", in: app.textFields["Commit summary"])
        clickVisible(app.buttons["Commit and Push"])
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 10))
        let saved = try repository.git("rev-parse", "HEAD")
        XCTAssertEqual(try repository.git("show", "HEAD:notes.txt"), "outgoing")
        XCTAssertNotEqual(try repository.git("--git-dir", offline.path, "rev-parse", "main"), saved)
        try FileManager.default.moveItem(at: offline, to: remote)
        clickVisible(app.buttons["Retry"])
        expectGit(saved, ["--git-dir", remote.path, "rev-parse", "main"])
        XCTAssertEqual(try repository.git("rev-parse", "HEAD"), saved)
        XCTAssertEqual(try repository.git("rev-list", "--count", "HEAD"), "2")
    }

    func testFailedPushCanBeRetriedAfterRemoteReturns() throws {
        let remote = try trackedRemote()
        let offline = remote.deletingLastPathComponent().appendingPathComponent("offline.git")
        try repository.git("commit", "--allow-empty", "-m", "Outgoing")
        try FileManager.default.moveItem(at: remote, to: offline)
        launch()
        clickVisible(app.buttons["Push"])
        app.typeKey(.return, modifierFlags: [])
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        clickVisible(app.buttons["Show details"])
        XCTAssertTrue(app.buttons["Hide details"].exists)
        try FileManager.default.moveItem(at: offline, to: remote)
        clickVisible(retry)
        expectSuccess("Pushed origin/main")
        XCTAssertEqual(try repository.git("--git-dir", remote.path, "rev-parse", "main"), try repository.git("rev-parse", "HEAD"))
    }
}
