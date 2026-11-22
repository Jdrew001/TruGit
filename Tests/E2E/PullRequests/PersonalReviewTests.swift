import XCTest

final class PersonalReviewTests: TruGitUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try repository.git("remote", "add", "origin", "https://github.com/example/review.git")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PullRequest", withExtension: "json"))
        app.launchEnvironment["TRUGIT_PULL_FIXTURE"] = fixture.path
        app.launchEnvironment["TRUGIT_FIXTURE_LOGIN"] = repository.root.lastPathComponent
    }

    func testReviewingMiddleFileAt125PercentPersistsAndCanBeUndone() throws {
        openReview()
        expectText("0 of 3 reviewed")
        try selectBravo()
        try clickRenderedLabel("Reviewed", whenReady: app.checkBoxes["Reviewed"])
        expectText("1 of 3 reviewed")

        app.terminate()
        openReview()
        expectText("1 of 3 reviewed")
        try selectBravo()
        XCTAssertEqual(app.checkBoxes["Reviewed"].value as? Int, 1)
        try clickRenderedLabel("Reviewed", whenReady: app.checkBoxes["Reviewed"])
        expectText("0 of 3 reviewed")
    }

    func testReviewAt75Percent() throws { try verifyReview(at: 75) }
    func testReviewAt100Percent() throws { try verifyReview(at: 100) }
    func testReviewAt150Percent() throws { try verifyReview(at: 150) }
    func testReviewAt175Percent() throws { try verifyReview(at: 175) }

    private func verifyReview(at zoom: Int) throws {
        openReview(at: zoom)
        if app.buttons["Sources/Bravo.swift"].exists {
            try selectBravo()
        } else {
            // Compact review uses a file picker in place of the file list.
            let picker = app.popUpButtons.matching(NSPredicate(format: "value == %@", "Sources/Alpha.swift")).firstMatch
            clickVisible(picker)
            app.menuItems["Sources/Bravo.swift"].click()
            expectText("Sources/Bravo.swift")
        }
        let checkbox = app.checkBoxes["Reviewed"]
        if checkbox.frame.maxX > app.windows.firstMatch.frame.maxX {
            // The workspace deliberately scrolls horizontally above its minimum logical width.
            app.scrollViews.firstMatch.scroll(byDeltaX: -600, deltaY: 0)
        }
        try clickRenderedLabel("Reviewed", whenReady: app.checkBoxes["Reviewed"])
        expectText("1 of 3 reviewed")
        try clickRenderedLabel("Reviewed", whenReady: app.checkBoxes["Reviewed"])
        expectText("0 of 3 reviewed")
    }

    private func openReview(at zoom: Int = 125) {
        launch(at: zoom)
        clickVisible(app.buttons["Pull Requests"])
        expectText("Review navigation")
        // With a narrow workspace, hide the inbox to expose the file navigator.
        if zoom == 125 && !app.buttons["Sources/Bravo.swift"].waitForExistence(timeout: 2) {
            clickVisible(app.buttons["Hide Sidebar"])
        }
    }

    private func selectBravo() throws {
        // The leading B can blend with the document icon at small sizes. The unique
        // suffix still lands inside the painted filename; verify the full selected path.
        try clickRenderedLabel("ravo", whenReady: app.buttons["Sources/Bravo.swift"])
        expectText("Sources/Bravo.swift")
    }
}
