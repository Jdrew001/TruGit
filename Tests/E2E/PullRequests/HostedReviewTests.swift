import XCTest

final class HostedReviewTests: TruGitUITestCase {
    private var receipt: URL { repository.root.appendingPathComponent(".git/request.json") }
    private var fixture: URL { repository.root.appendingPathComponent(".git/pull.json") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try repository.git("remote", "add", "origin", "https://github.com/example/review.git")
        let bundled = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "PullRequest", withExtension: "json"))
        try FileManager.default.copyItem(at: bundled, to: fixture)
        app.launchEnvironment["TRUGIT_PULL_FIXTURE"] = fixture.path
        app.launchEnvironment["TRUGIT_FIXTURE_LOGIN"] = repository.root.lastPathComponent
        app.launchEnvironment["TRUGIT_REQUEST_LOG"] = receipt.path
    }

    private func openPR() {
        launch()
        clickVisible(app.buttons["Pull Requests"])
        expectText("0 of 3 reviewed")
    }

    private func checkRequest(_ suffix: String, fields: [String: String]) throws {
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: self.receipt.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 8), .completed)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        XCTAssertEqual(json["path"] as? String, "/repos/example/review/" + suffix)
        XCTAssertEqual(json["fields"] as? [String: String], fields)
    }

    func testCommentAndReplyGoToTheirOwnThreads() throws {
        openPR()
        clickVisible(app.buttons["Conversation"])
        expectText("Fixture PR description.")
        enter("General feedback", in: app.textFields["Write a comment…"])
        clickVisible(app.buttons["Comment"])
        try checkRequest("issues/42/comments", fields: ["body": "General feedback"])
        try FileManager.default.removeItem(at: receipt)
        clickVisible(app.links["Reply"])
        enter("Thread reply", in: app.textFields["Write a reply…"])
        clickVisible(app.buttons["Send reply"])
        try checkRequest("pulls/42/comments/3/replies", fields: ["body": "Thread reply"])
    }

    func testCreatePullRequestUsesSelectedBranchesAndDescription() throws {
        try repository.git("switch", "-c", "topic")
        openPR()
        clickVisible(app.buttons["New PR"])
        let submit = app.buttons["Create pull request"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        enter("Fixture change", in: app.textFields["PR title"])
        enter("Verify these changes", in: app.descendants(matching: .any).matching(identifier: "Describe your changes…").firstMatch)
        clickVisible(submit)
        try checkRequest("pulls", fields: ["base": "main", "head": "topic", "title": "Fixture change", "body": "Verify these changes"])
    }

    func testAuthorCanOnlySubmitCommentOnOwnPullRequest() throws {
        app.launchEnvironment["TRUGIT_FIXTURE_LOGIN"] = "author"
        openPR()
        clickVisible(app.buttons["Submit review…"])
        expectText("You can comment on your own pull request.")
        XCTAssertFalse(app.buttons["Approve PR"].exists)
        XCTAssertFalse(app.buttons["Submit comment"].isEnabled)
        enter("Author follow-up", in: app.textFields["Write your review…"])
        clickVisible(app.buttons["Submit comment"])
        try checkRequest("pulls/42/reviews", fields: ["event": "COMMENT", "body": "Author follow-up", "commit_id": "abc123"])
    }

    func testApproveUsesReviewedCommit() throws {
        openPR()
        clickVisible(app.buttons["Submit review…"])
        clickVisible(app.sheets.buttons["Approve"])
        clickVisible(app.buttons["Approve PR"])
        try checkRequest("pulls/42/reviews", fields: ["event": "APPROVE", "body": "", "commit_id": "abc123"])
    }

    func testRequestChangesRequiresSummary() throws {
        openPR()
        clickVisible(app.buttons["Submit review…"])
        clickVisible(app.sheets.buttons["Request changes"].firstMatch)
        let submit = try XCTUnwrap(app.sheets.buttons.matching(identifier: "Request changes").allElementsBoundByIndex.last)
        XCTAssertFalse(submit.isEnabled)
        enter("Handle missing data", in: app.textFields["What needs to change?"])
        clickVisible(submit)
        try checkRequest("pulls/42/reviews", fields: ["event": "REQUEST_CHANGES", "body": "Handle missing data", "commit_id": "abc123"])
    }

    func testChangedHeadPreventsSubmittingStaleReview() throws {
        openPR()
        clickVisible(app.buttons["Submit review…"])
        clickVisible(app.sheets.buttons["Approve"])
        var content = try String(contentsOf: fixture, encoding: .utf8)
        content = content.replacingOccurrences(of: "abc123", with: "abc456")
        try content.write(to: fixture, atomically: true, encoding: .utf8)
        clickVisible(app.buttons["Approve PR"])
        expectText("The pull request changed. Refresh and review the latest changes before submitting.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }

    private func writePages(_ make: ([String: Any]) throws -> [String: Any]) throws {
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        data["pages"] = try make(data)
        try JSONSerialization.data(withJSONObject: data).write(to: fixture, options: .atomic)
    }

    func testPaginationIncludesFilesFromTheSecondPage() throws {
        try writePages { data in
            let files = try XCTUnwrap(data["files"] as? [[String: Any]])
            let route = "/repos/example/review/pulls/42/files||"
            return [
                route + "1": ["body": Array(files.prefix(2)), "headers": ["Link": "<https://api.github.com/next>; rel=\"next\""]],
                route + "2": ["body": Array(files.suffix(1))]
            ]
        }
        openPR()
        clickVisible(app.buttons["Sources/Charlie.swift"])
        expectText("Sources/Charlie.swift")
        clickVisible(app.checkBoxes["Reviewed"])
        expectText("1 of 3 reviewed")
    }

    func testDeniedInboxRecoversAfterRefresh() throws {
        try writePages { _ in
            ["/repos/example/review/pulls|open|1": ["body": ["message": "Access denied"], "status": 403]]
        }
        launch()
        clickVisible(app.buttons["Pull Requests"])
        expectText("GitHub returned 403. Access denied\nCheck the token’s repository access and organization approval.")
        try writePages { _ in [:] }
        clickVisible(app.buttons["Refresh pull requests"])
        expectText("0 of 3 reviewed")
    }

    func testClosedInboxThenOpenRestoresSelection() throws {
        openPR()
        clickVisible(app.radioButtons["Closed"])
        expectText("No closed pull requests")
        expectText("Select a pull request")
        clickVisible(app.radioButtons["Open"])
        expectText("0 of 3 reviewed")
    }

    func testPersonalReviewIsIsolatedBetweenAccounts() throws {
        openPR()
        clickVisible(app.buttons["Sources/Bravo.swift"])
        clickVisible(app.checkBoxes["Reviewed"])
        expectText("1 of 3 reviewed")
        app.terminate()
        app.launchEnvironment["TRUGIT_FIXTURE_LOGIN"] = "other-" + repository.root.lastPathComponent
        openPR()
        clickVisible(app.buttons["Sources/Bravo.swift"])
        XCTAssertEqual(app.checkBoxes["Reviewed"].value as? Int, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }

    func testMarkingIsPrivateAndChangedFileReturnsToQueue() throws {
        openPR()
        clickVisible(app.buttons["Sources/Bravo.swift"])
        clickVisible(app.checkBoxes["Reviewed"])
        expectText("1 of 3 reviewed")
        clickVisible(app.buttons["Next unreviewed"])
        expectText("Sources/Charlie.swift")
        let content = try String(contentsOf: fixture, encoding: .utf8)
        try content.replacingOccurrences(of: "\"bbb\"", with: "\"new-blob\"").write(to: fixture, atomically: true, encoding: .utf8)
        clickVisible(app.buttons["Refresh pull requests"])
        expectText("0 of 3 reviewed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }
}
