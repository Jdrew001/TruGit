import CoreImage
import Vision
import XCTest

@MainActor
class TruGitUITestCase: XCTestCase {
    let app = XCUIApplication()
    var repository: RepositoryFixture!

    override func setUpWithError() throws {
        #if !TRUGIT_E2E
        throw XCTSkip("Select the TruGit E2E scheme to launch the isolated app.")
        #else
        continueAfterFailure = false
        repository = try RepositoryFixture()
        let root = repository.root.path
        app.launchArguments = ["-repositorySession.v1", "{ paths = (\"\(root)\"); selectedPath = \"\(root)\"; }",
                               "-showLaunchAnimation", "NO", "-repositorySidebarExpanded", "YES",
                               "-workingChangesTree", "NO"]
        #endif
    }

    func launch(at percent: Int = 100) {
        if let i = app.launchArguments.firstIndex(of: "-appZoom") { app.launchArguments.removeSubrange(i...i + 1) }
        app.launchArguments += ["-appZoom", String(percent)]
        app.launch()
        let zoom = app.buttons["Reset app zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 10))
        XCTAssertEqual(zoom.value as? String, "\(percent) percent")
    }

    func enter(_ text: String, in field: XCUIElement) {
        clickVisible(field)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    func expectGit(_ expected: String, _ arguments: [String], file: StaticString = #filePath, line: UInt = #line) {
        let matches = NSPredicate { _, _ in (try? self.repository.runGit(arguments)) == expected }
        let wait = XCTNSPredicateExpectation(predicate: matches, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 8), .completed,
                       "git \(arguments) yielded \((try? repository.runGit(arguments)) ?? "an error"); expected \(expected)", file: file, line: line)
    }

    override func tearDownWithError() throws {
        guard let repository else { return }
        if (testRun?.failureCount ?? 0) > 0 {
            let state = try repository.git("status", "--porcelain", "--branch")
            let attachment = XCTAttachment(string: state)
            attachment.name = "Git state at failure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        if (testRun?.failureCount ?? 0) > 0, app.state == .runningForeground, app.windows.firstMatch.exists {
            let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            image.name = "Failure window"
            image.lifetime = .keepAlways
            add(image)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Failure hierarchy"
            add(hierarchy)
        }
        if app.state != .notRunning { app.terminate() }
        try FileManager.default.removeItem(at: repository.root)
    }

    /// For standard controls whose accessibility frame is part of the UI contract.
    func clickVisible(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)", file: file, line: line)
        if element.elementType == .button && !element.isEnabled {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "Disabled \(element)", file: file, line: line)
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Zoom regressions can move the accessibility frame and hit target together.
    /// Click the painted label, independently of both, as a person would.
    func clickRenderedLabel(_ label: String, whenReady element: XCUIElement,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)", file: file, line: line)
        let window = app.windows.firstMatch
        let screenshot = window.screenshot()
        let image = try XCTUnwrap(screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        // Restrict OCR to this pane. The region includes adjacent rows on both sides;
        // only the painted text determines the click, even if accessibility frames are offset.
        let frame = window.frame
        let scale = CGFloat(image.width) / frame.width
        let row = element.frame
        let width = min(frame.width, max(400, row.width + 72))
        let left = min(max(0, row.midX - frame.minX - width / 2), frame.width - width)
        let region = CGRect(x: left * scale,
                            y: (row.midY - frame.minY - 90) * scale,
                            width: width * scale, height: 180 * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let crop = try XCTUnwrap(image.cropping(to: region))
        let inverted = CIImage(cgImage: crop).applyingFilter("CIColorInvert")
        let input = try XCTUnwrap(CIContext().createCGImage(inverted, from: inverted.extent))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: input).perform([request])
        let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        let matches = try candidates.compactMap { candidate -> CGRect? in
            if let range = candidate.string.range(of: label) {
                return try candidate.boundingBox(for: range)?.boundingBox
            }
            // Small monospaced text can be recognized with a space around a dot.
            guard candidate.string.filter({ !$0.isWhitespace }) == label.filter({ !$0.isWhitespace }) else { return nil }
            return try candidate.boundingBox(for: candidate.string.startIndex..<candidate.string.endIndex)?.boundingBox
        }
        guard matches.count == 1, let box = matches.first else {
            add(XCTAttachment(screenshot: screenshot))
            XCTFail("Expected one visible label containing ‘\(label)’, found \(matches.count). Recognized \(candidates.map(\.string))", file: file, line: line)
            return
        }
        let x = region.minX + box.midX * region.width
        let y = region.minY + (1 - box.midY) * region.height
        window.coordinate(withNormalizedOffset: CGVector(dx: x / CGFloat(image.width), dy: y / CGFloat(image.height))).click()
    }

    func expectSuccess(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let notice = app.staticTexts[message].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "Missing success notification: " + message, file: file, line: line)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(notice.frame.midX, window.midX, file: file, line: line)
        XCTAssertLessThan(notice.frame.maxY, window.minY + window.height / 4, file: file, line: line)
    }

    func expectText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts[text].firstMatch.waitForExistence(timeout: 10), "Missing text: \(text)", file: file, line: line)
    }
}
