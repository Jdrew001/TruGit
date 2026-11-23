import XCTest

final class HistoryTests: TruGitUITestCase {
    func testGraphScrollsWithoutShiftingNeighboringColumns() throws {
        let tree = try repository.git("rev-parse", "HEAD^{tree}")
        let base = try repository.git("rev-parse", "HEAD")
        let parents = try (1...12).map { index in
            try repository.git("commit-tree", tree, "-p", base, "-m", "Parallel change \(index)")
        }
        let merge = try repository.runGit(["commit-tree", tree, "-m", "Dense graph"] + parents.flatMap { ["-p", $0] })
        try repository.git("update-ref", "refs/heads/main", merge)
        app.launchArguments += ["-historyGraphWidth", "54"]
        launch()

        let scroller = app.scrollBars["Scroll graph horizontally"].firstMatch
        XCTAssertTrue(scroller.waitForExistence(timeout: 5))
        let messageHeader = app.splitters["Commit message column width"]
        XCTAssertTrue(messageHeader.exists)
        let commit = app.staticTexts["Parallel change 1"].firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(scroller.frame.minY, commit.frame.maxY)
        let messageX = messageHeader.frame.midX
        scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).click()
        let value = try XCTUnwrap((scroller.value as? NSNumber)?.doubleValue)
        XCTAssertGreaterThan(value, 0)
        XCTAssertEqual(messageHeader.frame.midX, messageX, accuracy: 1)
    }

    func testViewAllFilesLoadsUnchangedContentFromSelectedCommit() throws {
        try repository.write("guide.txt", "Published instructions")
        try repository.git("add", ".")
        try repository.git("commit", "-m", "Instructions")
        try repository.write("change.txt", "latest")
        try repository.git("add", ".")
        try repository.git("commit", "-m", "Second snapshot")
        launch()
        clickVisible(app.buttons["main, checked-out local branch"].firstMatch)
        clickVisible(app.checkBoxes["View all files"])
        clickVisible(app.buttons["guide.txt"])
        expectText("Published instructions")
        clickVisible(app.buttons["Back to changed files"])
        XCTAssertTrue(app.checkBoxes["View all files"].exists)
    }

    func testBinaryFileShowsBinaryStateAndBackReturnsToWorktree() throws {
        let data = Data([0, 2, 10, 80, 255])
        let file = repository.root.appendingPathComponent("sample.bin")
        try data.write(to: file)
        launch()
        clickVisible(app.buttons["sample.bin, Untracked"])
        expectText("Binary File Changed")
        clickVisible(app.buttons["Back to changed files"])
        XCTAssertTrue(app.buttons["Stage sample.bin"].exists)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(try repository.git("status", "--porcelain"), "?? sample.bin")
    }
}
