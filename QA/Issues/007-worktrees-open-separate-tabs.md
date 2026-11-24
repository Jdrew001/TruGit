# 007 · Linked worktrees open separate repository tabs

### Reproduction

1. Add a repository to TruGit and create a linked worktree on a different branch.
2. Select that branch’s worktree action or click the worktree in the sidebar.
3. For the unavailable-worktree case, use a disposable linked checkout and remove its `.git` file while leaving the folder and Git registration in place. Select the branch again.

### Expected result

TruGit switches the existing repository tab to the linked checkout. The tab title and group survive the switch, and file actions use the selected checkout’s index. An unavailable checkout leaves the current checkout in place and identifies the broken registration.

### Observed result

The prior linked-worktree test expected a second tab named after the worktree folder. In the Kingdom Flow API repository on TruGit 0.2.21, Git listed the `release` branch in a temporary worktree with a missing `.git` file. TruGit offered to open it and displayed “not a git repository.”

### Regression coverage

[RevisionTests](../../Tests/E2E/Branches/RevisionTests.swift) checks same-tab navigation in both directions, staging in the selected worktree, an unavailable registration, and restoration of a session containing separate tabs for the same repository.
