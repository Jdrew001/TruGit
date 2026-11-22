# 004 · Commit search finds a match but gives the results list zero height

### Description

When searching commit messages at 75% or 100% app zoom, the popover reports a missing term correctly. Entering text that matches a known commit then leaves only the search field visible. The user has no visible row to select.

### Reproduction

1. Create a local repository with a commit titled `Locate the blue heron`. Verify that `git log --all --grep='blue heron' --format=%s` prints the subject.
2. Open the repository in TruGit at 75% zoom and click Search in the toolbar.
3. Enter `doesnotexist` and wait for “No matching commits”.
4. Replace the term with `blue heron`. Wait for the search to settle and try to click the matching commit.

```sh
xcodebuild test -scheme 'TruGit E2E' -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:TruGitUITests/WorkspaceTests/testSearchDistinguishesMatchingAndMissingCommit
```

### Expected Result

The matching subject and short SHA appear below the field. Clicking the result dismisses the popover and selects the matching commit in the graph.

### Actual Result

Fresh runs at 75% and 100% both measured a result height of 0.0 points for a Git-verified match. The no-match message disappears. Only the populated field remains visible. The accessibility hierarchy records the results scroll view as 252 points wide and **zero points high**. A second run searching specifically for the subject inside the popover also failed to find a selectable result.

### Evidence

[Search popover after entering a matching term](../Evidence/004-commit-search.png). The November 22 native test recorded the following hierarchy, cropped to the relevant elements.

```text
Popover       {{1488.0, 236.0}, {296.0, 68.0}}
  TextField   {{1509.0, 257.0}, {254.0, 20.0}}  value: blue heron
  ScrollView  {{1510.0, 282.0}, {252.0, 0.0}}
```

### Environment and data

TruGit d470c4d in its E2E configuration. macOS 27.0.1 on Apple silicon, Xcode 27.2, 1340 × 800-point workspace. Disposable local repository with the matching commit on main.

### Impact and data integrity

A user cannot navigate to a matching commit through the affected search popover. Searching is read-only.

### Relevant source or contract

[CommitSearch](../../TruGit/Workspace/RepositoryWorkspace.swift) creates a WorkspaceScrollView only when the query returns matches. The original view specified only a maximum height. [WorkspaceTests](../../Tests/E2E/Workspace/WorkspaceTests.swift) checks the no-match state, the selectable result and the destination.

### Classification

Fixed and verified on November 22, 2026. The popover sizes its list to the number of matches, up to 250 points. At 75% and 100%, the test searched for a missing commit and then selected a known result by its button label. The inspector showed the SHA of the selected commit.
