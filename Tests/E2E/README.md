# TruGit end-to-end tests

In Xcode, select **TruGit E2E** and press **⌘U**. From the project root on a Mac with Xcode and an active desktop session, run

```sh
xcodebuild test -scheme 'TruGit E2E' -destination 'platform=macOS' -parallel-testing-enabled NO
```

Append `-only-testing:TruGitUITests/PersonalReviewTests` to run a workflow, or append a test method after the class name to replay one scenario. Inspect the Test Report in Xcode for the failing action, window screenshot, and accessibility hierarchy. The report location also appears in xcodebuild’s output.

| Directory | Workflows |
| --- | --- |
| Branches | Branch creation and switching, merge, tag creation, checkout undo/redo, cherry-pick, revert, rebase, reset and linked worktrees |
| Conflicts | Abort and continue a conflicted merge, select a side, save the resolution and verify the staged bytes |
| History | Historical contents of unchanged files, binary diffs and return navigation |
| Worktree | Select and inspect files, stage and unstage, discard, commit, amend and stash |
| Remotes | Fetch and pull from a peer, publish, check the success notification, recover from a failed push |
| PullRequests | Select a file and mark it reviewed, persist and clear progress, recheck changed files, post a review, comment, reply and create a PR |
| Workspace | Repository onboarding and clone, tab aliases and groups, commit search, settings, zoom controls and divider drags |
| Support | App launch, physical clicks, screenshot-based text location, disposable Git repositories and the local GitHub transport |
| Fixtures | API responses consumed by the production GitHub decoder |

The test host uses its own bundle identifier and preferences. Each test creates a temporary repository. Local remotes are disposable bare repositories. Hosted tests use a unique fixture account and an in-process GitHub transport. The write tests inspect the request body and destination. Live GitHub authentication, server-side permissions and signed updater installation require separate checks.

Put each new journey beside the feature it exercises. Use visible controls and verify the outcome independently, for example by reading a Git ref, the index, the bytes on disk, or the saved mark after relaunch. For pointer regressions, use `clickRenderedLabel` with a unique visible label. It finds the label in a screenshot, which catches cases where the accessibility frame and hit target move together while the label stays in place.

Each confirmed defect gets [one issue file](../../QA/Issues) with the setup, steps, expected and actual results, evidence and regression command. A failing assertion by itself is a lead to investigate.
