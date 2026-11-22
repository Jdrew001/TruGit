# 005 · Clicking Both in the conflict editor misses the visible button at 125%

### Description

In the conflict editor, clicking the painted Both button fails to select the resolution at one notch above default zoom. The merge cannot advance until a choice is registered.

### Reproduction

1. Create a repository with one conflicted file. Start with `base` in shared.txt and commit different replacements, `current` and `incoming`, on main and other. Merge other into main.
2. Set TruGit to 125%, open shared.txt from the conflict list and locate the first hunk.
3. Click the center of the visible word **Both**. Check the unresolved count and whether **Save and Stage** becomes available.

```sh
xcodebuild test -scheme 'TruGit E2E' -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:TruGitUITests/ConflictTests/testClickingPaintedConflictChoiceAt125Percent
```

### Expected Result

The editor keeps the current line followed by the incoming line, marks the hunk resolved and enables Save and Stage.

### Actual Result

The click left the hunk unresolved and Save and Stage disabled. The test located the text in the rendered window and clicked at approximately 64% of the window width and 36% of its height.

### Evidence

[Conflict editor immediately after the physical click](../Evidence/005-conflict-control.png). No checkmark appears on Both. The test and screenshot use the same run. The Both control’s accessibility frame began at screen x = 1081.5 points with a width of 44.5 points. The click on the rendered text was near screen x = 1176 points.

### Environment and data

TruGit d470c4d, E2E configuration, macOS 27.0.1 on Apple silicon, Xcode 27.2, 1340 × 800-point workspace, 125% app zoom. The conflict has exactly one hunk.

### Impact and data integrity

A second run waited four seconds for Save and Stage to enable. It stayed disabled, and git status still reported `UU shared.txt` on main. A separate 100% test successfully selected the incoming side, staged the expected content and continued the merge.

### Relevant source or contract

[ConflictDiffView](../../TruGit/Conflicts/ConflictDiffView.swift) originally presented the choices inside a native split view and enables saving once all hunks have a resolution. [ConflictTests](../../Tests/E2E/Conflicts/ConflictTests.swift) uses a rendered-text click and checks the index if the choice succeeds.

### Classification

Fixed and verified on November 22, 2026. The hunk list and result editor now share the zoomed SwiftUI coordinate space. At 125%, clicking the rendered word Both enabled Save and Stage. Reading the Git index confirmed both versions were staged in the correct order.
