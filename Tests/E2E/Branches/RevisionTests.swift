import XCTest

final class RevisionTests: TruGitUITestCase {
    private func topicCommit() throws -> String {
        try repository.git("switch", "-c", "topic")
        try repository.write("topic.txt", "topic")
        try repository.git("add", ".")
        try repository.git("commit", "-m", "Topic change")
        try repository.git("switch", "main")
        return try repository.git("rev-parse", "topic")
    }

    private func context(_ branch: String, _ option: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", branch + ", ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.rightClick()
        let item = app.menuItems[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }

    private func confirm(_ title: String) {
        let actions = app.sheets.buttons.matching(identifier: title)
        XCTAssertTrue(actions.firstMatch.waitForExistence(timeout: 5))
        // The grid and footer share the action name. Return invokes the sheet’s default button.
        let footer = actions.allElementsBoundByIndex.max { $0.frame.midY < $1.frame.midY }
        guard let footer else { return XCTFail("Missing confirmation for " + title) }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: footer)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        app.typeKey(.return, modifierFlags: [])
    }

    func testSwitchToRemoteBranchCreatesTrackingBranchThenReusesIt() throws {
        let remote = repository.root.appendingPathComponent(".git/peer.git")
        try repository.git("init", "--bare", remote.path)
        try repository.git("remote", "add", "peer", remote.path)
        try repository.git("push", "peer", "HEAD:refs/heads/feature/nested")
        let ref = "peer/feature/nested"
        let tip = try repository.git("rev-parse", ref)
        launch()
        context(ref, "Switch to " + ref)
        expectGit("feature/nested", ["branch", "--show-current"])
        XCTAssertEqual(try repository.git("rev-parse", "HEAD"), tip)
        XCTAssertEqual(try repository.git("rev-parse", "--abbrev-ref", "@{upstream}"), ref)

        context("main", "Switch to main")
        expectGit("main", ["branch", "--show-current"])
        context(ref, "Switch to feature/nested")
        expectGit("feature/nested", ["branch", "--show-current"])
        XCTAssertEqual(try repository.git("branch", "--format=%(refname:short)"), "feature/nested\nmain")
    }

    func testGraphSwitchKeepsBranchTrackingAnotherRemoteIntact() throws {
        for remote in ["origin", "peer"] {
            let bare = repository.root.appendingPathComponent(".git/" + remote + ".git")
            try repository.git("init", "--bare", bare.path)
            try repository.git("remote", "add", remote, bare.path)
            try repository.git("push", remote, "HEAD:refs/heads/topic")
        }
        try repository.git("branch", "--track", "topic", "origin/topic")
        launch()
        let row = app.tables.firstMatch.descendants(matching: .tableRow).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).rightClick()
        let item = app.menuItems["Switch to peer/topic"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        expectGit("peer-topic", ["branch", "--show-current"])
        XCTAssertEqual(try repository.git("rev-parse", "--abbrev-ref", "@{upstream}"), "peer/topic")
        XCTAssertEqual(try repository.git("rev-parse", "--abbrev-ref", "topic@{upstream}"), "origin/topic")
    }

    func testSwitchUndoRedoAndBranchFilter() throws {
        _ = try topicCommit()
        launch()
        let filter = app.textFields["Filter branches and tags"]
        enter("does-not-exist", in: filter)
        expectText("No matching branches or tags.")
        clickVisible(app.buttons["Clear branch filter"])
        context("topic", "Switch to topic")
        expectGit("topic", ["branch", "--show-current"])
        clickVisible(app.buttons["Undo"])
        expectGit("main", ["branch", "--show-current"])
        clickVisible(app.buttons["Redo"])
        expectGit("topic", ["branch", "--show-current"])
    }

    func testCherryPickThenRevertPreservesTopic() throws {
        let original = try topicCommit()
        launch()
        context("topic", "Cherry-pick Tip onto main…")
        confirm("Cherry-pick")
        expectGit("topic", ["show", "HEAD:topic.txt"])
        context("main", "Revert Tip Commit on “main”…")
        confirm("Revert commit")
        expectGit("", ["ls-tree", "--name-only", "HEAD"])
        XCTAssertEqual(try repository.git("rev-parse", "topic"), original)
    }

    func testBatchReviewCanRemoveRestoreAndSquash() throws {
        let original = try topicCommit()
        launch()
        context("topic", "Cherry-pick Tip onto main…")
        clickVisible(app.sheets.buttons["Add from graph…"])
        clickVisible(app.buttons["Back to review"])
        clickVisible(app.buttons["Remove " + String(original.prefix(7)) + " from cherry-pick"])
        expectText("No commits to apply")
        clickVisible(app.links["Undo remove"])
        clickVisible(app.buttons["Squash into one"])
        enter("Reviewed batch", in: app.textFields["Commit message"])
        clickVisible(app.buttons["Squash and cherry-pick"])
        expectGit("Reviewed batch", ["log", "-1", "--format=%s"])
        XCTAssertEqual(try repository.git("show", "HEAD:topic.txt"), "topic")
        XCTAssertEqual(try repository.git("rev-parse", "topic"), original)
    }

    func testRebaseReplaysCurrentBranchOntoSelectedTip() throws {
        let tip = try topicCommit()
        try repository.write("main.txt", "main")
        try repository.git("add", ".")
        try repository.git("commit", "-m", "Main change")
        launch()
        context("topic", "Rebase main onto This Branch…")
        confirm("Rebase")
        expectGit(tip, ["rev-parse", "main^"])
        XCTAssertEqual(try repository.git("ls-tree", "--name-only", "main"), "main.txt\ntopic.txt")
    }

    func testSoftResetMovesHeadAndPreservesIndex() throws {
        let base = try repository.git("rev-parse", "HEAD")
        try repository.git("branch", "before")
        try repository.write("saved.txt", "preserve me")
        try repository.git("add", ".")
        try repository.git("commit", "-m", "Saved change")
        launch()
        context("before", "Reset “main” to This Tip…")
        confirm("Reset branch")
        expectGit(base, ["rev-parse", "HEAD"])
        XCTAssertEqual(try repository.git("show", ":saved.txt"), "preserve me")
    }

    func testHardResetRequiresDiscardConfirmationAndLeavesOtherRefIntact() throws {
        let before = try repository.git("rev-parse", "HEAD")
        try repository.git("branch", "before")
        try repository.write("tracked.txt", "committed")
        try repository.git("add", ".")
        try repository.git("commit", "-m", "Before reset")
        try repository.git("branch", "backup")
        try repository.write("tracked.txt", "uncommitted")
        launch()
        context("before", "Reset “main” to This Tip…")
        clickVisible(app.radioButtons["Hard"])
        let submit = app.sheets.buttons.matching(identifier: "Reset branch").allElementsBoundByIndex.max { $0.frame.midY < $1.frame.midY }
        XCTAssertFalse(try XCTUnwrap(submit).isEnabled)
        clickVisible(app.checkBoxes["Discard changes on “main”"])
        confirm("Reset branch")
        expectGit(before, ["rev-parse", "main"])
        XCTAssertEqual(try repository.git("status", "--porcelain"), "")
        XCTAssertEqual(try repository.git("show", "backup:tracked.txt"), "committed")
    }

    func testUnmergedBranchDeletionCanBeCancelledAndExplicitlyConfirmed() throws {
        let topic = try topicCommit()
        launch()
        func openDeletion() {
            let row = app.buttons["topic, Local"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.rightClick()
            app.menuItems["Delete…"].hover()
            app.menuItems["Delete Local Branch…"].click()
        }
        openDeletion()
        clickVisible(app.sheets.buttons["Cancel"])
        XCTAssertEqual(try repository.git("rev-parse", "topic"), topic)
        openDeletion()
        clickVisible(app.checkBoxes["Allow deletion if the local branch has unmerged commits"])
        clickVisible(app.sheets.buttons["Delete"])
        expectSuccess("Deleted branch")
        expectGit("", ["branch", "--list", "topic"])
        XCTAssertEqual(try repository.git("branch", "--show-current"), "main")
    }

    func testChangedRemoteTipSurvivesReviewedDeletion() throws {
        _ = try topicCommit()
        let remote = repository.root.appendingPathComponent(".git/remote.git")
        try repository.git("init", "--bare", remote.path)
        try repository.git("remote", "add", "origin", remote.path)
        try repository.git("push", "-u", "origin", "topic")
        let newer = try repository.git("rev-parse", "main")
        launch()
        let row = app.buttons["topic, Local"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        app.menuItems["Delete…"].hover()
        app.menuItems["Delete Remote Branch…"].click()
        let submit = app.sheets.buttons["Delete"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        // Another client moves the remote after the deletion review was opened.
        try repository.git("--git-dir", remote.path, "update-ref", "refs/heads/topic", newer)
        clickVisible(submit)
        expectText("Couldn’t finish branch deletion")
        XCTAssertEqual(try repository.git("--git-dir", remote.path, "rev-parse", "topic"), newer)
        XCTAssertEqual(try repository.git("show", "topic:topic.txt"), "topic")
    }

    func testOpenOtherWorktreeWithoutChangingOriginalBranch() throws {
        let linked = repository.root.appendingPathComponent(".git/linked-checkout")
        try repository.git("worktree", "add", "-b", "linked", linked.path)
        launch()
        context("linked", "Open “linked” worktree")
        XCTAssertTrue(app.buttons["Close linked-checkout"].waitForExistence(timeout: 10))
        XCTAssertEqual(try repository.git("branch", "--show-current"), "main")
        XCTAssertEqual(try repository.git("-C", linked.path, "branch", "--show-current"), "linked")
    }
}
