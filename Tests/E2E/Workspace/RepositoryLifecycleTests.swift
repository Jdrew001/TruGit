import XCTest

final class RepositoryLifecycleTests: TruGitUITestCase {
    private func openClone() {
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Clone Repository…"].click()
        XCTAssertTrue(app.buttons["Clone"].waitForExistence(timeout: 5))
    }

    func testLocalCloneValidatesCollisionAndOpensCorrectCommit() throws {
        launch()
        openClone()
        enter(repository.root.path, in: app.textFields["HTTPS or SSH URL"])
        clickVisible(app.buttons["Clone"])
        expectText("Couldn’t Clone Repository")
        let name = "clone-" + UUID().uuidString
        let destination = repository.root.deletingLastPathComponent().appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: destination) }
        enter(name, in: app.textFields["Folder name"])
        clickVisible(app.buttons["Clone"])
        XCTAssertTrue(app.buttons["Close " + name].waitForExistence(timeout: 10))
        XCTAssertEqual(try repository.git("-C", destination.path, "rev-parse", "HEAD"), try repository.git("rev-parse", "HEAD"))
        clickVisible(app.buttons["Close " + name])
        XCTAssertTrue(app.buttons[repository.root.lastPathComponent].exists)
    }

    func testAliasGroupRenameCollapseAndUngroup() {
        launch()
        let tab = app.buttons[repository.root.lastPathComponent]
        tab.rightClick()
        app.menuItems["Edit Tab Alias…"].click()
        enter("My project", in: app.sheets.textFields.firstMatch)
        clickVisible(app.buttons["Save"])
        let alias = app.buttons["My project"]
        XCTAssertTrue(alias.waitForExistence(timeout: 5))
        alias.rightClick()
        app.menuItems["Move Tab to Group"].hover()
        app.menuItems["New Group…"].click()
        enter("QA group", in: app.textFields["Group name"])
        clickVisible(app.buttons["Save"])
        let group = app.buttons["QA group"]
        clickVisible(group)
        XCTAssertFalse(alias.exists)
        clickVisible(group)
        XCTAssertTrue(alias.exists)
        group.rightClick()
        app.menuItems["Rename Group…"].click()
        enter("Renamed", in: app.textFields["Group name"])
        clickVisible(app.buttons["Save"])
        app.buttons["Renamed"].rightClick()
        app.menuItems["Ungroup Tabs"].click()
        XCTAssertTrue(alias.exists)
        alias.rightClick()
        app.menuItems["Remove Alias"].click()
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
    }

    func testAddFolderInitializeAndReopenExistingRepo() throws {
        let name = "empty-" + UUID().uuidString
        let folder = repository.root.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        launch()
        app.typeKey("o", modifierFlags: .command)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(folder.path)
        app.typeKey(.return, modifierFlags: [])
        clickVisible(app.buttons["Choose"])
        clickVisible(app.buttons["Initialize Repository"])
        XCTAssertTrue(app.buttons["Close " + name].waitForExistence(timeout: 10))
        XCTAssertEqual(try repository.git("-C", folder.path, "rev-parse", "--show-toplevel"), folder.path)
        clickVisible(app.buttons["Close " + name])
        app.typeKey("o", modifierFlags: .command)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(folder.path)
        app.typeKey(.return, modifierFlags: [])
        clickVisible(app.buttons["Choose"])
        XCTAssertTrue(app.buttons["Close " + name].waitForExistence(timeout: 10))
    }
}
