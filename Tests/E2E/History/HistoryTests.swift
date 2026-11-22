import XCTest

final class HistoryTests: TruGitUITestCase {
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
