# TruGit QA

Run the [native E2E suite](../Tests/E2E/README.md) against the isolated test host. Each [issue](Issues) has its own reproduction, outcome and regression command. Keep a report after a fix so its trigger remains discoverable.

## Issue history

| ID | Trigger | Status |
| --- | --- | --- |
| [006](Issues/006-replacing-merge-result-terminates-app.md) | Typing over selected merge-result text terminates TruGit | Fixed and verified |
| [004](Issues/004-commit-search-hides-matching-results.md) | Commit search returns an invisible results list | Fixed and verified |
| [005](Issues/005-conflict-choice-misses-at-125-percent.md) | Clicking Both leaves a merge hunk unresolved at 125% | Fixed and verified |
| [003](Issues/003-sidebar-divider-overshoots-at-nondefault-zoom.md) | Resizing the sidebar at nondefault zoom | Fixed and verified |
| [001](Issues/001-worktree-row-selection.md) | Changed-file selection after one zoom increment | Earlier fix, regression retained |
| [002](Issues/002-pull-request-row-selection.md) | PR file selection at 125% | Earlier fix, regression retained |

## Verification after fixes on November 22, 2026

One complete native run on an Apple silicon MacBook Air with macOS 27.0.1 and Xcode 27.2 passed all **67 tests**, with zero failures, skips or expected failures. XCTest recorded 16 minutes and 40 seconds of test execution. The regular Debug app also built successfully.

The run verified manual merge replacement and stale-file protection, selecting Both at 125% and staging both sides, navigating from commit search to the expected SHA at 75% and 100%, and physical divider travel across the tested panes and zoom levels. The search test addresses the result button by its accessible subject. The divider tests keep the other panes at known widths and drag in a direction with room to travel.

## Baseline before fixes on November 22, 2026

The full run executed 67 tests on an Apple silicon MacBook Air with macOS 27.0.1 and Xcode 27.2. Xcode recorded 55 passes, 12 failures and zero skips. Eleven failures trace to the four issues subsequently fixed above. Six expose the same divider scaling problem, two expose invisible commit search results, one exposes the conflict-choice hit target and two encounter the merge editor crash.

The twelfth failure came from the test's screenshot reader interpreting the first letter of Bravo.swift as an 8. The revised test clicks the uniquely matching rendered text and still requires the exact path Sources/Bravo.swift, the updated review count, persistence after reopening and successful removal of the mark. It passed twice consecutively at 125% after the adjustment. Across the full run and this focused retest, 56 distinct tests passed and 11 exposed product defects.

The file-selection and personal-review scenarios cover 75%, 100%, 125%, 150% and 175%. The separate live check used [faithtab-service PR #94](https://github.com/Jdrew001/faithtab-service/pull/94) at 125%. Automated PR write tests check the destination and request body using a local GitHub transport. The Release configuration also built successfully with the production bundle identifier.

## Git integration checks on November 22, 2026

A separate Debug build of d470c4d exercised TruGit’s Git action implementation against temporary working repositories and a local bare remote. These checks reached the real Git executable. The UI results are tracked separately.

| Executed workflow | Independent result |
| --- | --- |
| Cherry-pick, revert, rebase, fast-forward and merge | Checked file contents, selected branch, parent count and rebase direction. A merge commit was cherry-picked with an explicit mainline. |
| Conflict continue, skip and abort | Checked operation markers and the destination commit after each action. |
| Push and force-with-lease | A non-fast-forward push was rejected. A reviewed lease succeeded. A stale lease preserved the intervening remote commit. |
| Create, rename, tag and publish | Checked the local ref, annotated tag type, upstream assignment and rejection when the remote destination already existed. |
| Soft, mixed and hard reset | Checked target HEAD, index and working tree separately. |
| Resolution of merge and rebase conflicts | Used three hunks with mixed left, right and both choices, CRLF line endings, an executable file and a nondefault conflict marker size. Checked stale-edit rejection, incomplete resolution rejection, exact staged bytes, file mode and final ancestry. |
| Multi-commit cherry-pick, revert and squash | Applied three commits in a different order, checked their subjects and tree, reverted the batch in reverse order, then squashed the three patches into one commit with the reviewed message. |
| Binary and modify/delete conflicts | Chose incoming versions and checked the resulting bytes and deletion after merge completion. |
| Deletion scopes | Checked local-only, remote-only and combined branch removal, worktree-only removal, and worktree removal combined with local, remote or both branches. Dirty, locked, main and unmerged checkouts were protected. Verified explicit override, nonmatching upstream names and stale remote lease rejection. |
| Paths, status and diffs | Checked a staged rename involving Unicode, brackets, a tab and a newline. Checked separate HEAD/index and index/working comparisons, executable-bit-only change, symlink target text and the three stash sections. |
| Tab session model | Moved tabs and whole groups across each other, removed a middle member, changed group color and name, revealed a collapsed tab, removed an empty group, and reloaded saved tab order, selection and alias. This exercised the session model directly. |

## Additional acceptance cases

These cases supplement the named XCTest workflows. The table is a scenario inventory. The dated run results in this report identify which steps have execution evidence. Use disposable repositories and local bare remotes for operations that change Git state. For every successful Git action, check the top-right notification, the repository named in it, and the resulting Git state. For a failed operation, inspect the error details, retry destination and local changes.

| Surface | Steps and observable outcome |
| --- | --- |
| Graph and history | Use divergent branches, a merge commit and several refs on one commit. Select the graph node, its ref and an overflow badge in turn. Check the commit SHA and selected ref. Scroll, resize the ref column, open the hover stack and drag from a non-first row. Check the source and destination shown in Branch Actions. |
| Multi-commit actions | Select nonadjacent commits, cherry-pick onto a disposable destination, reorder, remove, undo remove, append from graph, and apply. Verify commit order and file bytes. Repeat as a squash and as a batch revert. Select both mainline options on a merge commit and inspect the resulting tree. |
| Branch and tag lifecycle | Rename a branch, create a tracking branch, delete merged and unmerged branches, cancel and confirm local-only, remote-only and combined deletion. Check the reviewed refs with git show-ref and git ls-remote. Push lightweight and annotated tags, verifying both the tag object and peeled commit. |
| Push destinations | Try no remote, one remote, two remotes, detached HEAD, a differently named upstream, a stale remote tip, and a non-fast-forward push. Check that Publish, Push and Force Push with Lease address the intended ref. Move the remote between review and submit and verify that a stale lease preserves its newer commit. |
| History rewrites | Exercise each reset mode with staged and unstaged bytes. Check HEAD, index and working tree separately. Cancel the hard reset. Repeat with the destination checked out in another worktree. |
| Worktree and stash | Include rename, deletion, executable-bit change, symlink, empty file, literal glob and Unicode filenames. Compare staged and unstaged versions. Inspect a stash with staged, unstaged and untracked contents. Apply, pop, cancel deletion and delete a named entry. Compare stash IDs and file bytes. |
| Conflicts | Create multiple hunks, add/add, modify/delete and binary conflicts. Choose each side, both sides or edit the result. Edit on disk with the editor open and check stale-draft protection. Exercise continue, abort and skip for merge, cherry-pick and rebase where offered. Check operation state and final parents. |
| Repositories and tabs | Add multiple folders including a nested repository and a non-repository, partially select initialization, cancel, open the same repo twice and relaunch. Move tabs within and between groups, collapse the active group and close the last tab. Check order, selection and aliases after restart. |
| Preferences and desktop integration | Change workspace defaults, restart and check both file lists. Try launch animation with Reduce Motion. Use copy path, branch, SHA and summary actions and inspect the clipboard. Reveal a file in Finder and open Terminal at the selected repository. |
| PR browsing and review | Test open/closed lists, empty inbox, pagination, multiple remotes, missing patch, binary and renamed files, collapsed sidebar, and a removed or changed file after refresh. Check review isolation between accounts, repositories and PRs. Exercise failed requests and retry with fixture responses. |
| Window and input | At 75%, 100%, 125%, 150% and 175%, use a narrow window and a wide one. Click rendered text at the top, middle and bottom of scrolled lists. Resize both panes, inspect clipping, navigate by keyboard and verify focused controls, shortcuts and dialogs. |
| External services | Use a disposable provider account and repository to check actual sign-in, Keychain restore/disconnect, access denied, expired credentials and authorized writes. Use a signed distribution build and a test update feed to check download, cancellation, relaunch and version. Record provider and build IDs for completed runs. |
