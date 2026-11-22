# 001 · Clicking a changed file selects an adjacent row at 125%

### Description

The user reported clicking one file in the right-hand Changes panel and getting the file below it after zooming in one notch. The target matters for both inspecting a diff and staging individual files.

### Reproduction

1. Open a repository with untracked Alpha.txt, Bravo.txt and Charlie.txt. Stage two additional files named Amber.txt and Delta.txt.
2. Set app zoom to 125% and open the working changes.
3. Click the painted text of Bravo.txt. Read the diff title.
4. Stage Bravo.txt and check the index. Click its name in Staged Changes, then unstage it.

### Expected Result

Bravo.txt opens. Staging and unstaging changes only Bravo.txt. Amber.txt and Delta.txt stay staged throughout.

### Actual Result

On the affected layout, the pointer could select the file below the clicked name. The user observed this after increasing zoom one notch.

### Evidence

The automated regression clicks the text in a window screenshot, checks the selected path and reads the Git index after both actions. Run it from the project root on a Mac with a desktop session.

```sh
xcodebuild test -scheme 'TruGit E2E' -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:TruGitUITests/WorktreeTests/testClickingMiddleFileOpensItsDiffAndStagesOnlyThatFileAt125Percent
```

### Environment and data

Local macOS workspace, working tree view, flat file list, 125% app zoom. The fixture uses five disposable files and needs no account.

### Impact and data integrity

The wrong diff can open. The initial user report described selection. It did not establish that a real file was incorrectly staged.

### Relevant source or contract

[WorktreePanel](../../TruGit/Changes/WorktreePanel.swift) and [WorktreeTests](../../Tests/E2E/Worktree/WorktreeTests.swift). The selected file should match the painted row under the pointer.

### Classification

Confirmed defect in the earlier layout. Fix recorded in commit d679277. Retain the visual regression.
