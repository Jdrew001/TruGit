import XCTest

final class ConflictTests: TruGitUITestCase {
    private func prepareConflict() throws {
        try repository.write("shared.txt", "base\n")
        try repository.git("add", ".")
        try repository.git("commit", "-m", "Base file")
        try repository.git("switch", "-c", "other")
        try repository.write("shared.txt", "incoming\n")
        try repository.git("commit", "-am", "Incoming")
        try repository.git("switch", "main")
        try repository.write("shared.txt", "current\n")
        try repository.git("commit", "-am", "Current")
        XCTAssertThrowsError(try repository.git("merge", "other"))
        XCTAssertEqual(try repository.git("status", "--porcelain"), "UU shared.txt")
    }

    func testAbortMergeRestoresOriginalTree() throws {
        try prepareConflict()
        let original = try repository.git("rev-parse", "HEAD")
        launch()
        clickVisible(app.buttons["Abort…"])
        clickVisible(app.buttons["Abort Merge"])
        expectGit("", ["status", "--porcelain"])
        XCTAssertEqual(try repository.git("rev-parse", "HEAD"), original)
        XCTAssertEqual(try repository.git("show", ":shared.txt"), "current")
    }

    func testChooseIncomingStageAndContinueMerge() throws {
        try prepareConflict()
        launch()
        clickVisible(app.buttons["shared.txt, Conflict"])
        let save = app.buttons["Save and Stage"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertFalse(save.isEnabled)
        clickVisible(app.buttons["Conflict 1, Right"])
        clickVisible(save)
        expectGit("incoming", ["show", ":shared.txt"])
        clickVisible(app.buttons["Continue Merge"])
        expectGit("", ["status", "--porcelain"])
        XCTAssertEqual(try repository.git("rev-parse", "HEAD^2"), try repository.git("rev-parse", "other"))
    }

    func testReplaceMergedResultAndStageManualText() throws {
        try prepareConflict()
        launch()
        clickVisible(app.buttons["shared.txt, Conflict"])
        clickVisible(app.buttons["Conflict 1, Left"])
        enter("Manually combined", in: app.textViews["Merged result code editor"])
        XCTAssertEqual(app.state, .runningForeground)
        clickVisible(app.buttons["Save and Stage"])
        expectGit("Manually combined", ["show", ":shared.txt"])
    }

    func testManualConflictEditWarnsWhenFileChangesOnDisk() throws {
        try prepareConflict()
        launch()
        clickVisible(app.buttons["shared.txt, Conflict"])
        clickVisible(app.buttons["Conflict 1, Left"])
        enter("Manually combined", in: app.textViews.firstMatch)
        try repository.write("shared.txt", "An independent edit")
        app.typeKey("r", modifierFlags: .command)
        expectText("The file changed on disk. Copy your edits before reopening it.")
        XCTAssertFalse(app.buttons["Save and Stage"].isEnabled)
        XCTAssertEqual(try repository.git("status", "--porcelain"), "UU shared.txt")
        XCTAssertEqual(try String(contentsOf: repository.root.appendingPathComponent("shared.txt"), encoding: .utf8), "An independent edit")
    }

    func testBinaryConflictStagesIncomingBytes() throws {
        let file = repository.root.appendingPathComponent("asset.bin")
        try Data([0, 1]).write(to: file)
        try repository.git("add", ".")
        try repository.git("commit", "-m", "Binary base")
        try repository.git("switch", "-c", "other")
        let incoming = Data([0, 2])
        try incoming.write(to: file)
        try repository.git("commit", "-am", "Binary incoming")
        try repository.git("switch", "main")
        try Data([0, 3]).write(to: file)
        try repository.git("commit", "-am", "Binary current")
        XCTAssertThrowsError(try repository.git("merge", "other"))
        launch()
        clickVisible(app.buttons["asset.bin, Conflict"])
        clickVisible(app.buttons["Right · Incoming changes"])
        clickVisible(app.buttons["Save and Stage"])
        expectGit("", ["diff", "--name-only", "--diff-filter=U"])
        XCTAssertEqual(try repository.git("rev-parse", ":asset.bin"), try repository.git("rev-parse", "other:asset.bin"))
        XCTAssertEqual(try Data(contentsOf: file), incoming)
    }

    func testClickingPaintedConflictChoiceAt125Percent() throws {
        try prepareConflict()
        launch(at: 125)
        clickVisible(app.buttons["shared.txt, Conflict"])
        try clickRenderedLabel("Both", whenReady: app.buttons["Conflict 1, Both"])
        let save = app.buttons["Save and Stage"]
        let resolved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 4), .completed, "Selecting Both should resolve the only hunk")
        clickVisible(save)
        expectGit("current\nincoming", ["show", ":shared.txt"])
    }
}
