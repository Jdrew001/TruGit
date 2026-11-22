# 006 · Replacing text in the merge result can terminate TruGit

### Description

A reviewer resolving a one-hunk text conflict can lose the editor when typing over a selected resolution. This occurs at 100% zoom before pressing Save and Stage.

### Reproduction

1. On main, commit shared.txt containing one line, `base`. Create a branch named other.
2. On other, replace the line with `incoming` and commit. On main, replace it with `current` and commit. Merge other into main to produce a conflict.
3. Open the conflicted file in TruGit. Click **Left** for the first conflict.
4. Click in **Merged Result**, press **⌘A**, and type `Manually combined` over the selected text.

```sh
xcodebuild test -scheme 'TruGit E2E' -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:TruGitUITests/ConflictTests/testReplaceMergedResultAndStageManualText
```

### Expected Result

The editor retains the replacement text. Saving stages exactly the edited result.

### Actual Result

TruGit raised an AppKit text range exception during replacement and the test lost the application process. The user could not reach Save and Stage.

### Evidence

The host diagnostic on November 22 at 12:54:42 recorded an NSRangeException while processing a character edit. The excerpt identifies the failing data and the app frames.

```text
NSRangeException: -[NSBigMutableString characterAtIndex:]: Index 7 out of bounds; string length 1
MergeEditor.Coordinator.color(_:)
MergeEditor.Coordinator.textStorage(_:didProcessEditing:range:changeInLength:)
XCTest: Application com.drewatkison.TruGit.E2E is not running
```

### Environment and data

TruGit d470c4d, macOS 27.0.1 on Apple silicon, Xcode 27.2, 1340 × 800-point workspace, 100% zoom. Local disposable repository, no remote.

### Impact and data integrity

A second, isolated run terminated during the same edit at 12:57:03 with the same index-7 / length-1 exception. After the exit, an independent Git read returned `## main` and `UU shared.txt`. The merge remained unresolved and the typed result was never staged.

### Relevant source or contract

[MergeEditor](../../TruGit/Conflicts/MergeEditor.swift) previously recolored text while processing character edits. [ConflictTests](../../Tests/E2E/Conflicts/ConflictTests.swift) reproduces the replacement and checks the staged result.

### Classification

Fixed and verified on November 22, 2026. Highlighting now runs after the text view finishes processing the edit. The replacement test staged the exact manually typed string. The external-edit test retained the independent file contents, showed the stale-file warning and disabled Save and Stage. Both tests passed individually and again in the full-suite run.
