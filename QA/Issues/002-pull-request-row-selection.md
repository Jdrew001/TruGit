# 002 · A pull request file can receive a click intended for another row at 125%

### Description

The PR changed-files list had a hit-target offset at 125% app zoom. A reviewer could intend to inspect one file and open another before marking it reviewed.

### Reproduction

1. Open a pull request containing at least three changed files.
2. Zoom the workspace to 125%. Select the middle file by clicking its painted filename.
3. Compare the path on the diff with the path clicked. Toggle Reviewed and check which file received the mark.
4. Reopen the same PR and check the saved mark. Clear it and check the reviewed count.

### Expected Result

The clicked path opens and receives the personal mark. Reopening preserves the mark and clearing it updates the count.

### Actual Result

On the affected layout the visible row and its clickable region were offset. A real PR was subsequently checked at 125% in a separate test window after the layout change.

### Evidence

The live verification used faithtab-service PR 94. The repeatable regression uses three synthetic files so the suite can run offline. It clicks text found in the screenshot, reads the selected path and checks persistence after a relaunch.

```sh
xcodebuild test -scheme 'TruGit E2E' -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:TruGitUITests/PersonalReviewTests
```

### Environment and data

macOS PR review workspace, 125% app zoom. The real-PR check used a separate window. The automated test uses an isolated account and local API responses.

### Impact and data integrity

A reviewer could inspect the wrong diff. The mark is personal to TruGit. The test checks local progress across relaunches.

### Relevant source or contract

[PersonalFileReview](../../TruGit/GitHub/PersonalFileReview.swift) and [PersonalReviewTests](../../Tests/E2E/PullRequests/PersonalReviewTests.swift).

### Classification

Confirmed defect in the earlier layout. Fix recorded in d470c4d. Retain the visual regression.
