import XCTest

final class BranchTests: TruGitUITestCase {
    func testBranchFoldersAndSidebarSectionsPersistAcrossRelaunch() throws {
        try repository.git("branch", "release/stable")
        try repository.git("branch", "release/2026/november")
        try repository.git("switch", "release/stable")
        try repository.git("tag", "v1.2.3")
        let upstream = repository.root.appendingPathComponent(".git/sidebar-origin.git")
        try repository.git("init", "--bare", upstream.path)
        try repository.git("remote", "add", "origin", upstream.path)
        try repository.git("push", "origin", "HEAD:refs/heads/release/nightly", "HEAD:refs/heads/release/stable")
        try repository.git("fetch", "origin")

        let sidebarFlag = try XCTUnwrap(app.launchArguments.firstIndex(of: "-repositorySidebarExpanded"))
        app.launchArguments.removeSubrange(sidebarFlag...sidebarFlag + 1)
        launch()
        if app.buttons["Show Sidebar"].exists { clickVisible(app.buttons["Show Sidebar"]) }

        let branches = app.buttons["Local, 3"]
        let remotes = app.buttons["Remote, 2"]
        let worktrees = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Worktrees,")).firstMatch
        let stashes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stashes,")).firstMatch
        let release = app.buttons["branch-folder-release"]
        let year = app.buttons["branch-folder-release/2026"]
        let nightly = app.buttons["origin/release/nightly, Remote"].firstMatch
        let remoteStable = app.buttons["origin/release/stable, Remote"].firstMatch
        let remoteRelease = app.buttons["remote-branch-folder-origin/release"]
        let november = app.buttons["release/2026/november, Local"].firstMatch
        let tags = app.buttons["Tags, 1"]
        XCTAssertTrue(november.waitForExistence(timeout: 10))
        XCTAssertFalse(nightly.exists)
        clickVisible(remotes)
        XCTAssertTrue(nightly.waitForExistence(timeout: 10))
        XCTAssertTrue(remoteStable.exists)
        clickVisible(remoteRelease)
        XCTAssertFalse(nightly.exists)
        XCTAssertTrue(november.exists)
        clickVisible(year)
        XCTAssertFalse(november.exists)
        clickVisible(release)
        XCTAssertFalse(year.exists)

        enter("november", in: app.textFields["Filter branches and tags"])
        XCTAssertTrue(november.waitForExistence(timeout: 10))
        clickVisible(app.buttons["Clear branch filter"])
        XCTAssertEqual(release.value as? String, "Collapsed")

        clickVisible(tags)
        clickVisible(worktrees)
        clickVisible(stashes)
        clickVisible(branches)
        clickVisible(app.buttons["Hide Sidebar"])
        app.terminate()
        launch()
        XCTAssertTrue(app.buttons["Show Sidebar"].waitForExistence(timeout: 10))
        clickVisible(app.buttons["Show Sidebar"])

        XCTAssertEqual(branches.value as? String, "Collapsed")
        XCTAssertEqual(remotes.value as? String, "Expanded")
        XCTAssertEqual(remoteRelease.value as? String, "Collapsed")
        XCTAssertEqual(tags.value as? String, "Collapsed")
        XCTAssertEqual(worktrees.value as? String, "Expanded")
        XCTAssertEqual(stashes.value as? String, "Expanded")
        clickVisible(branches)
        XCTAssertEqual(release.value as? String, "Collapsed")
        clickVisible(release)
        clickVisible(remoteRelease)
        XCTAssertTrue(nightly.waitForExistence(timeout: 10))
        XCTAssertEqual(year.value as? String, "Collapsed")
        clickVisible(year)
        XCTAssertTrue(november.waitForExistence(timeout: 10))
    }

    func testCreateBranchRejectsDuplicateAndSwitchesToNewBranch() throws {
        launch()
        clickVisible(app.buttons["Branch"])
        let field = app.textFields["Branch name"]
        enter("main", in: field)
        XCTAssertFalse(app.buttons["Create and Switch"].isEnabled)
        enter("qa-branch", in: field)
        clickVisible(app.buttons["Create and Switch"])
        expectGit("qa-branch", ["branch", "--show-current"])
        XCTAssertEqual(try repository.git("rev-parse", "main"), try repository.git("rev-parse", "qa-branch"))
    }

    func testTagSuggestionAnnotationAndDuplicateGuard() throws {
        try repository.git("tag", "v1.2.3")
        launch()
        clickVisible(app.buttons["Tag"])
        clickVisible(app.descendants(matching: .any).matching(identifier: "Use v1.2.4").firstMatch)
        enter("QA annotated release", in: app.textFields["Optional tag message"])
        clickVisible(app.buttons["Create Tag"])
        expectGit("tag", ["cat-file", "-t", "v1.2.4"])
        XCTAssertEqual(try repository.git("tag", "-l", "v1.2.4", "--format=%(contents:subject)"), "QA annotated release")
        clickVisible(app.buttons["Tag"])
        enter("v1.2.4", in: app.textFields["e.g. v1.0.0"])
        expectText("This tag already exists in this repository.")
        XCTAssertFalse(app.buttons["Create Tag"].isEnabled)
        clickVisible(app.buttons["Cancel"])
    }

    func testCreateAndPushTagPublishesExactObject() throws {
        let remote = repository.root.appendingPathComponent(".git/tags.git")
        try repository.git("init", "--bare", remote.path)
        try repository.git("remote", "add", "origin", remote.path)
        launch()
        clickVisible(app.buttons["Tag"])
        enter("verified-release", in: app.textFields["e.g. v1.0.0"])
        enter("QA tag", in: app.textFields["Optional tag message"])
        app.sheets.popUpButtons.firstMatch.click()
        app.menuItems["Push to origin"].click()
        clickVisible(app.buttons["Create and Push Tag"])
        expectSuccess("Create tag succeeded")
        let tag = try repository.git("rev-parse", "refs/tags/verified-release")
        XCTAssertEqual(try repository.git("--git-dir", remote.path, "rev-parse", "refs/tags/verified-release"), tag)
        XCTAssertEqual(try repository.git("--git-dir", remote.path, "rev-parse", "verified-release^{}"), try repository.git("rev-parse", "HEAD"))
    }

    func testMergeChangesTreeAndCreatesTwoParentCommit() throws {
        try repository.git("switch", "-c", "topic")
        try repository.write("topic.txt", "merged content")
        try repository.git("add", ".")
        try repository.git("commit", "-m", "Topic work")
        let topic = try repository.git("rev-parse", "HEAD")
        try repository.git("switch", "main")
        launch()
        clickVisible(app.buttons["topic, Local"].firstMatch)
        clickVisible(app.buttons["Merge"])
        clickVisible(app.sheets.buttons["Merge"])
        expectGit(topic, ["rev-parse", "HEAD^2"])
        XCTAssertEqual(try repository.git("show", "HEAD:topic.txt"), "merged content")
    }
}
