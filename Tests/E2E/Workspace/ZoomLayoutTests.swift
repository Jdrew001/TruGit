import XCTest

final class ZoomLayoutTests: TruGitUITestCase {
    func testSidebarDragAtDefaultZoom() { verifyDrag(at: 100) }
    func testSidebarDragAt75Percent() { verifyDrag(at: 75) }
    func testSidebarDragAt125Percent() { verifyDrag(at: 125) }
    func testSidebarDragAt150Percent() { verifyDrag(at: 150) }
    func testSidebarDragAt175Percent() { verifyDrag(at: 175) }

    func testInspectorDragAt125Percent() { verifyDrag(at: 125, label: "Inspector width", minimumWidth: 190, growsLeft: true) }
    func testReferenceColumnDragAt125Percent() { verifyDrag(at: 125, label: "Branch / Tag column width", minimumWidth: 54) }

    private func verifyDrag(at zoom: Int, label: String = "Sidebar width", minimumWidth: CGFloat = 150, growsLeft: Bool = false) {
        // Other panes retain their widths between launches and can crowd this divider.
        if label != "Sidebar width" { app.launchArguments += ["-repositorySidebarWidth", "224"] }
        if label != "Inspector width" { app.launchArguments += ["-historyInspectorWidth", "294"] }
        launch(at: zoom)
        let divider = app.descendants(matching: .any).matching(identifier: label).firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let startX = divider.frame.midX
        let handle = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        guard let value = divider.value, let width = Double(String(describing: value)) else {
            return XCTFail("Expected the divider to expose its current width")
        }
        let canShrink = (width - minimumWidth) * CGFloat(zoom) / 100 >= 41
        let delta: CGFloat = canShrink == growsLeft ? 40 : -40
        handle.click(forDuration: 0.15, thenDragTo: handle.withOffset(CGVector(dx: delta, dy: 0)))
        XCTAssertEqual(divider.frame.midX - startX, delta, accuracy: 3, "\(label) should finish under the pointer at \(zoom)%")
    }
}
