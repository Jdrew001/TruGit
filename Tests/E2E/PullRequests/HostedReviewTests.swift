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

    private func checkRequest(_ suffix: String, method: String = "POST", fields: [String: String]) throws {
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: self.receipt.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 8), .completed)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, method)
        XCTAssertEqual(json["path"] as? String, "/repos/example/review/" + suffix)
        XCTAssertEqual(json["fields"] as? [String: String], fields)
    }

    func testClosingRequiresConfirmationAndMovesPullRequestToClosed() throws {
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var closed = try XCTUnwrap(data["pull"] as? [String: Any])
        closed["state"] = "closed"
        var writes = try XCTUnwrap(data["writes"] as? [String: Any])
        writes["/repos/example/review/pulls/42"] = closed
        data["writes"] = writes
        try JSONSerialization.data(withJSONObject: data).write(to: fixture, options: .atomic)

        openPR()
        let close = app.buttons["Close pull request…"]
        clickVisible(close)
        clickVisible(app.buttons["Cancel"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))

        clickVisible(close)
        clickVisible(app.buttons["Close Pull Request"])
        try checkRequest("pulls/42", method: "PATCH", fields: ["state": "closed"])
        expectText("No open pull requests")
        XCTAssertFalse(close.exists)
        XCTAssertFalse(app.buttons["Submit review…"].isEnabled)

        clickVisible(app.radioButtons["Closed"])
        let item = app.buttons["pull-request-42"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertTrue(item.label.hasSuffix("Closed"))
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

    func testExpandedInboxShowsMetadataAndFindsAPullOutsideTheList() throws {
        try writePages { data in
            var other = try XCTUnwrap(data["pull"] as? [String: Any])
            other["number"] = 88
            other["title"] = "Move billing to the new ledger"
            other["user"] = ["login": "octavia"]
            other["draft"] = true
            return ["/search/issues||1|repo:example/review is:pr is:open author:octavia": ["body": ["items": [other]]]]
        }
        openPR()
        clickVisible(app.buttons["Expand pull request list"])
        expectText("Author")
        expectText("Updated")
        let original = app.buttons["pull-request-42"]
        XCTAssertTrue(original.exists)
        XCTAssertTrue(original.label.contains("Review navigation"))
        XCTAssertTrue(original.label.contains("author"))
        XCTAssertTrue(original.label.contains("2026"))

        enter("@octavia", in: app.textFields["Search pull requests"])
        let result = app.buttons["pull-request-88"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains("Move billing to the new ledger"))
        XCTAssertTrue(result.label.contains("octavia"))
        XCTAssertTrue(result.label.contains("Draft"))
        XCTAssertFalse(original.exists)
    }

    func testDiffShowsOldAndNewCodeAndKeepsFileAcrossTabs() throws {
        openPR()
        expectText("Old")
        expectText("New")
        for line in ["let size = 20", "let size = 50", "tenant.inbox"] {
            let code = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", line, line)).firstMatch
            XCTAssertTrue(code.waitForExistence(timeout: 10))
        }
        clickVisible(app.buttons["Wrap lines"])
        clickVisible(app.buttons["Wrap lines"])
        clickVisible(app.buttons["Sources/Bravo.swift"])
        clickVisible(app.buttons["Conversation"])
        expectText("Fixture PR description.")
        clickVisible(app.buttons["Files changed"])
        expectText("Sources/Bravo.swift")
        expectText("struct Bravo {}")
    }

    func testSlowConversationCanBeLeftAndARequestFailureCanBeRetried() throws {
        let route = "/repos/example/review/issues/42/comments||1"
        try writePages { _ in
            [route: ["body": ["message": "Conversation unavailable"], "status": 503, "delayMilliseconds": 5_000]]
        }
        openPR()
        clickVisible(app.buttons["Conversation"])
        app.buttons["Files changed"].click()
        expectText("Sources/Alpha.swift")
        XCTAssertTrue(app.buttons["Submit review…"].isEnabled)

        clickVisible(app.buttons["Conversation"])
        expectText("GitHub returned 503. Conversation unavailable")
        try writePages { _ in [:] }
        clickVisible(app.buttons["Reload"])
        expectText("First comment")
    }

    func testLargeConversationKeepsRepliesAndLongMessagesBounded() throws {
        try writePages { _ in
            let root: [String: Any] = ["id": 3, "user": ["login": "author"], "body": "Thread for large review",
                                       "path": "Sources/Alpha.swift", "line": 25, "diff_hunk": "@@ -24 +24 @@\n-old()\n+new()"]
            let replies: [[String: Any]] = (0..<180).map { index in
                ["id": 100 + index, "user": ["login": "author"], "path": "Sources/Alpha.swift",
                 "in_reply_to_id": 3, "body": "Reply number \(index)"]
            }
            let long = "Long review message\n" + String(repeating: "**Detail** with `inline code`.\n", count: 1_200)
            let conversation: [[String: Any]] = (0..<400).map { index in
                ["id": 1_000 + index, "user": ["login": "reviewer"], "body": index == 0 ? long : "Discussion \(index)"]
            }
            let inline = "/repos/example/review/pulls/42/comments||"
            var pages: [String: Any] = [
                inline + "1": ["body": [root] + Array(replies.prefix(99)),
                                "headers": ["Link": "<https://api.github.com/next>; rel=\"next\""]],
                inline + "2": ["body": Array(replies.dropFirst(99))],
            ]
            for page in 0..<4 {
                var response: [String: Any] = ["body": Array(conversation[(page * 100)..<((page + 1) * 100)])]
                if page < 3 { response["headers"] = ["Link": "<https://api.github.com/next>; rel=\"next\""] }
                pages["/repos/example/review/issues/42/comments||\(page + 1)"] = response
            }
            return pages
        }
        openPR()
        clickVisible(app.buttons["Conversation"])
        expectText("Threads 1–25 of 401")
        expectText("Thread for large review")
        expectText("Reply number 3")
        XCTAssertFalse(app.staticTexts["Reply number 4"].exists)
        app.scrollViews["pull-request-conversation"].scroll(byDeltaX: 0, deltaY: -180)
        clickVisible(app.links["Show 12 more replies"])
        expectText("Reply number 4")

        clickVisible(app.buttons["Latest threads"])
        expectText("Discussion 399")
        XCTAssertFalse(app.staticTexts["Thread for large review"].exists)
        clickVisible(app.buttons["Previous threads"])
        expectText("Threads 376–400 of 401")
        expectText("Discussion 374")
        clickVisible(app.buttons["Next threads"])
        expectText("Discussion 399")

        clickVisible(app.buttons["Files changed"])
        expectText("Sources/Alpha.swift")
        clickVisible(app.buttons["Conversation"])
        expectText("Discussion 399")
        clickVisible(app.buttons["First threads"])
        expectText("Thread for large review")
    }

    func testLargePatchAndMissingPatchAreBothNavigable() throws {
        try writePages { data in
            var files = try XCTUnwrap(data["files"] as? [[String: Any]])
            let generated = String(repeating: "x", count: 40_000)
            files[0]["patch"] = "@@ -0,0 +1,2 @@\n+let buffer = \"\(generated)\"\n+let finished = true"
            files[1].removeValue(forKey: "patch")
            return ["/repos/example/review/pulls/42/files||1": ["body": files]]
        }
        openPR()
        clickVisible(app.buttons["Next patch page"])
        expectText("let finished = true")
        clickVisible(app.buttons["Sources/Bravo.swift"])
        expectText("No text diff")
        clickVisible(app.buttons["Sources/Charlie.swift"])
        expectText("struct Charlie {}")
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
