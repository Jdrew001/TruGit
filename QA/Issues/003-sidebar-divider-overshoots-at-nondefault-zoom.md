# 003 · Pane dividers do not follow the pointer at nondefault zoom

### Description

Dragging the repository sidebar divider moves it by a different distance than the pointer travels. Zooming in makes the divider overshoot. At 125%, the same extra travel was reproduced on the right inspector and the Branch / Tag column.

### Reproduction

1. Open a local repository, show the left sidebar and set the app zoom to 125%.
2. Start near the middle of the divider’s resize range.
3. Press the sidebar divider and drag it horizontally by 40 screen points. Release and compare its position with the pointer.
4. Repeat at 150%, then at 100% as a control. The automated test uses a ±3-point tolerance.

```sh
xcodebuild test -scheme 'TruGit E2E' -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:TruGitUITests/ZoomLayoutTests
```

### Expected Result

The divider follows the pointer. A 40-point drag moves it approximately 40 screen points when neither width limit is reached.

### Actual Result

| App zoom | Pointer displacement | Divider displacement |
| --- | ---: | ---: |
| 75% | −40 points | −30 points |
| 100% | 40 points | Within 3 points of the pointer |
| 125% | +40 points | +50 points |
| 150% | −40 points | −60 points |
| 175% | +40 points | +70 points |

At 125%, both additional dividers moved 50 points for a 40-point drag (left for the inspector, right for the Branch / Tag column).

### Evidence

The native UI test records the splitter’s screen position, sends a drag with a known horizontal displacement, and measures the splitter again. The November 22 run produced the following assertion at 125%.

```text
XCTAssertEqualWithAccuracy failed: ("50.0") is not equal to ("40.0") +/- ("3.0")
```

The [window after the 125% drag](../Evidence/003-sidebar-after-drag.png) shows the final sidebar position. The displacement comparison comes from the two geometry readings.

### Environment and data

TruGit d470c4d, E2E configuration, macOS 27.0.1 (26A434), Apple silicon, Xcode 27.2 (27B52). The test used the 1340 × 800-point workspace and a disposable repository with one commit. No remote or account is required.

### Impact and data integrity

A user adjusting the sidebar must compensate for the zoom factor to place it accurately. The test measures UI geometry. It performs no Git action.

### Relevant source or contract

[WidthDivider in RepositoryWorkspace](../../TruGit/Workspace/RepositoryWorkspace.swift) previously added the distance in window points directly to the stored layout width. [ZoomLayoutTests](../../Tests/E2E/Workspace/ZoomLayoutTests.swift) measures the resulting on-screen travel.

### Classification

Fixed and verified on November 22, 2026. The divider converts window movement into layout points using the current zoom. Sidebar drags matched the physical 40-point movement at all five zoom levels. Inspector and Branch / Tag divider drags also matched at 125%.
