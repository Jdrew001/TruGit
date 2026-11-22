import XCTest

final class BranchTests: TruGitUITestCase {
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
