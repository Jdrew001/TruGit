import XCTest

final class WorkspaceTests: TruGitUITestCase {
    func testZoomButtonsLimitsAndReset() {
        app.launch() // Exercise the actual zoom preference without a command-line override.
        let reset = app.buttons["Reset app zoom"]
        clickVisible(reset)
        for level in [125, 150, 175] {
            clickVisible(app.buttons["Zoom In"])
            XCTAssertEqual(reset.value as? String, "\(level) percent")
        }
        XCTAssertFalse(app.buttons["Zoom In"].isEnabled)
        for level in [150, 125, 100, 75] {
            clickVisible(app.buttons["Zoom Out"])
            XCTAssertEqual(reset.value as? String, "\(level) percent")
        }
        XCTAssertFalse(app.buttons["Zoom Out"].isEnabled)
        app.typeKey("0", modifierFlags: .command)
        XCTAssertEqual(reset.value as? String, "100 percent")
    }

    func testSearchDistinguishesMatchingAndMissingCommit() throws { try verifySearch(at: 75) }
    func testMatchingCommitSearchAtDefaultZoom() throws { try verifySearch(at: 100) }

    private func verifySearch(at zoom: Int) throws {
        try repository.git("commit", "--allow-empty", "-m", "Locate the blue heron")
        let targetID = try repository.git("rev-parse", "HEAD")
        try repository.git("commit", "--allow-empty", "-m", "Later work")
        XCTAssertEqual(try repository.git("log", "--all", "--grep=blue heron", "--format=%s"), "Locate the blue heron")
        launch(at: zoom)
        clickVisible(app.buttons["Search"])
        let field = app.textFields["Search commit messages on all branches"]
        enter("doesnotexist", in: field)
        expectText("No matching commits")
        enter("blue heron", in: field)
        let results = app.popovers.scrollViews.firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(results.frame.height, 0, "The search results need visible height to select a matching commit")
        let result = app.popovers.buttons["Locate the blue heron"].firstMatch
        clickVisible(result)
        XCTAssertFalse(field.exists)
        expectText("commit:  " + String(targetID.prefix(7)))
    }

    func testSettingsSectionsAndDevelopmentUpdateStatus() {
        launch(at: 150)
        clickVisible(app.buttons["Settings"])
        clickVisible(app.buttons["Workspace"])
        expectText("File lists")
        clickVisible(app.buttons["GitHub"])
        expectText("Personal access token")
        clickVisible(app.buttons["Updates"])
        expectText("This is a development build. Automatic updates are available in signed distribution builds.")
    }

    func testFeedbackCreatesIssuesInTruGitWithVersion() throws {
        try repository.git("remote", "add", "origin", "https://github.com/example/other.git")
        let fixture = repository.root.appendingPathComponent("feedback.json")
        let receipt = repository.root.appendingPathComponent("issue.json")
        let destination = "/repos/Jdrew001/TruGit/issues"
        let responses: [String: Any] = ["pull": [:], "files": [], "writes": [destination: ["number": 42]]]
        try JSONSerialization.data(withJSONObject: responses).write(to: fixture)
        app.launchEnvironment["TRUGIT_PULL_FIXTURE"] = fixture.path
        app.launchEnvironment["TRUGIT_REQUEST_LOG"] = receipt.path
        launch()

        let version = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ AND value CONTAINS %@",
                                                           "TruGit ", " · Build ")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        let installedVersion = try XCTUnwrap(version.value as? String)

        for (action, heading, label) in [("Report a Bug", "Bug report", "bug"),
                                         ("Request a Feature", "Feature request", "enhancement")] {
            let menu = app.menuButtons["Feedback"]
            clickVisible(menu)
            menu.menuItems[action + "…"].click()

            let submit = app.buttons["Submit Issue"]
            XCTAssertTrue(submit.waitForExistence(timeout: 5))
            XCTAssertFalse(submit.isEnabled)
            enter(" Example feedback ", in: app.textFields["Title"])
            XCTAssertFalse(submit.isEnabled)
            enter("Example details", in: app.textViews["Details"].firstMatch)
            clickVisible(submit)
            expectText("Created TruGit issue #42.")
            XCTAssertTrue(app.links["View Issue"].exists)

            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
            XCTAssertEqual(request["path"] as? String, destination)
            let fields = try XCTUnwrap(request["fields"] as? [String: Any])
            XCTAssertEqual(fields["title"] as? String, "Example feedback")
            XCTAssertEqual(fields["labels"] as? [String], [label])
            XCTAssertEqual(fields["body"] as? String, "## \(heading)\n\nExample details\n\n## App version\n\n" + installedVersion)
            clickVisible(app.buttons["Done"])
        }
    }

    func testCloseLastTabAndCancelEmptyClone() {
        launch()
        app.typeKey("w", modifierFlags: .command)
        expectText("Add a Git Repository")
        clickVisible(app.buttons["Clone Repository…"])
        XCTAssertFalse(app.buttons["Clone"].isEnabled)
        clickVisible(app.buttons["Cancel"])
        expectText("Add a Git Repository")
    }
}
