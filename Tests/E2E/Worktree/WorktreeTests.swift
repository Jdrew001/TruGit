import XCTest

final class WorktreeTests: TruGitUITestCase {
    func testClickingMiddleFileOpensItsDiffAndStagesOnlyThatFileAt125Percent() throws {
        for name in ["Alpha.txt", "Bravo.txt", "Charlie.txt"] { try repository.write(name, name) }
        for name in ["Amber.txt", "Delta.txt"] { try repository.write(name, name) }
        try repository.git("add", "Amber.txt", "Delta.txt")
        launch(at: 125)
        try clickRenderedLabel("Bravo.txt", whenReady: app.buttons["Bravo.txt, Untracked"])
        expectText("Bravo.txt")

        clickVisible(app.buttons["Stage Bravo.txt"])
        XCTAssertTrue(app.buttons["Unstage Bravo.txt"].waitForExistence(timeout: 10))
        XCTAssertEqual(try repository.git("diff", "--cached", "--name-only"), "Amber.txt\nBravo.txt\nDelta.txt")
        try clickRenderedLabel("Bravo.txt", whenReady: app.buttons["Bravo.txt, Added"])
        expectText("Bravo.txt")
        clickVisible(app.buttons["Unstage Bravo.txt"])
        XCTAssertTrue(app.buttons["Stage Bravo.txt"].waitForExistence(timeout: 10))
        XCTAssertEqual(try repository.git("diff", "--cached", "--name-only"), "Amber.txt\nDelta.txt")
    }

    func testChangedFileSelectionAt75Percent() throws { try verifySelection(at: 75) }
    func testChangedFileSelectionAt100Percent() throws { try verifySelection(at: 100) }
    func testChangedFileSelectionAt150Percent() throws { try verifySelection(at: 150) }
    func testChangedFileSelectionAt175Percent() throws { try verifySelection(at: 175) }

    private func verifySelection(at zoom: Int) throws {
        for name in ["Alpha.txt", "Bravo.txt", "Charlie.txt"] { try repository.write(name, name) }
        launch(at: zoom)
        try clickRenderedLabel("Bravo.txt", whenReady: app.buttons["Bravo.txt, Untracked"])
        expectText("Bravo.txt")
        XCTAssertEqual(try repository.git("diff", "--cached", "--name-only"), "")
    }

    func testTreeStagesOnlySelectedFolderAndHandlesLiteralPaths() throws {
        let folder = repository.root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try repository.write("Sources/[ab].txt", "literal")
        try repository.write("Sources/a.txt", "neighbor")
        try repository.write("outside.txt", "outside")
        // Set the initial display mode before launch, then exercise the visible folder controls.
        let preference = try XCTUnwrap(app.launchArguments.firstIndex(of: "-workingChangesTree"))
        app.launchArguments[preference + 1] = "YES"
        launch()
        clickVisible(app.buttons["Expand All"])
        clickVisible(app.buttons["Stage Sources/[ab].txt"])
        expectSuccess("Staged changes")
        expectGit("Sources/[ab].txt", ["diff", "--cached", "--name-only"])
        clickVisible(app.buttons["Stage Sources"])
        expectGit("Sources/[ab].txt\nSources/a.txt", ["diff", "--cached", "--name-only"])
        clickVisible(app.buttons["Unstage All"])
        expectSuccess("Unstaged changes")
        expectGit("", ["diff", "--cached", "--name-only"])
        XCTAssertEqual(try repository.git("status", "--porcelain", "-uall"), "?? Sources/[ab].txt\n?? Sources/a.txt\n?? outside.txt")
    }

    func testDiscardCanBeCancelledAndRestoresOnlyUnstagedBytes() throws {
        try repository.write("notes.txt", "committed")
        try repository.git("add", ".")
        try repository.git("commit", "-m", "Base file")
        try repository.write("notes.txt", "staged")
        try repository.git("add", "notes.txt")
        try repository.write("notes.txt", "working")
        launch()
        let discard = app.buttons["Discard unstaged changes"]
        clickVisible(discard)
        clickVisible(app.buttons["Cancel"])
        XCTAssertEqual(try String(contentsOf: repository.root.appendingPathComponent("notes.txt"), encoding: .utf8), "working")
        clickVisible(discard)
        clickVisible(app.buttons["Discard 1 unstaged file changes"])
        expectGit("", ["diff", "--name-only"])
        XCTAssertEqual(try repository.git("show", ":notes.txt"), "staged")
        XCTAssertEqual(try repository.git("show", "HEAD:notes.txt"), "committed")
    }

    func testStashAndPopPreserveUntrackedBytes() throws {
        try repository.write("notes.txt", "do not lose these bytes\n")
        launch(at: 75)
        clickVisible(app.buttons["Stash"])
        expectGit("", ["status", "--porcelain"])
        XCTAssertFalse(try repository.git("stash", "list").isEmpty)
        clickVisible(app.buttons["Pop"])
        expectGit("?? notes.txt", ["status", "--porcelain"])
        XCTAssertEqual(try repository.git("stash", "list"), "")
        XCTAssertEqual(try String(contentsOf: repository.root.appendingPathComponent("notes.txt"), encoding: .utf8),
                       "do not lose these bytes\n")
    }

    func testApplyThenDeleteNamedStashKeepsAppliedBytes() throws {
        try repository.write("keep.txt", "kept")
        try repository.git("stash", "push", "-u", "-m", "QA entry")
        let original = try repository.git("rev-parse", "refs/stash")
        launch()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "QA entry")).firstMatch
        let section = app.buttons["Stashes, 1"]
        if section.value as? String == "Collapsed" { clickVisible(section) }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        app.menuItems["Apply Stash"].click()
        expectSuccess("Applied stash")
        XCTAssertEqual(try repository.git("rev-parse", "refs/stash"), original)
        row.rightClick()
        app.menuItems["Delete Stash…"].click()
        clickVisible(app.buttons["Cancel"])
        XCTAssertEqual(try repository.git("rev-parse", "refs/stash"), original)
        row.rightClick()
        app.menuItems["Delete Stash…"].click()
        clickVisible(app.buttons["Delete Stash"])
        expectGit("", ["stash", "list"])
        XCTAssertEqual(try String(contentsOf: repository.root.appendingPathComponent("keep.txt"), encoding: .utf8), "kept")
    }

    func testStageAllCommitAndAmendFromKeyboard() throws {
        try repository.write("notes.txt", "first")
        launch()
        clickVisible(app.buttons["Stage All Changes"])
        expectGit("notes.txt", ["diff", "--cached", "--name-only"])
        enter("Original subject", in: app.textFields["Commit summary"])
        app.typeKey(.return, modifierFlags: .command)
        expectGit("Original subject", ["log", "-1", "--format=%s"])
        expectSuccess("Commit succeeded")
        try repository.write("notes.txt", "second")
        let wip = app.descendants(matching: .any).matching(identifier: "WIP, uncommitted changes").firstMatch
        clickVisible(wip)
        clickVisible(app.buttons["Stage All Changes"])
        clickVisible(app.checkBoxes["Amend previous commit"])
        enter("Revised subject", in: app.textFields["Commit summary"])
        app.typeKey(.return, modifierFlags: .command)
        expectGit("Revised subject", ["log", "-1", "--format=%s"])
        XCTAssertEqual(try repository.git("rev-list", "--count", "HEAD"), "2")
        XCTAssertEqual(try repository.git("show", "HEAD:notes.txt"), "second")
    }
}
