# TruGit workspace review

Compared the supplied wide GitKraken workspace and branch-label crop with native TruGit windows showing a selected merge in a local test repository.

| Area | Observed result |
| --- | --- |
| Branch labels | The first build displayed a horizontal scrollbar under two labels. The revised build fits labels on one line and opens a native menu when space runs out. With four refs at one commit, the row displayed the current branch and +3. Selecting Show Label in Graph moved another branch into the visible position. |
| Toolbar | The first render hid the current repository and branch names. The revised selectors display both values beneath their captions. |
| Layout | At laptop and ultrawide widths, the graph columns line up with the commit records. The right inspector scales with the window and supports manual resizing. |
| Commit inspection | Path and Tree views show changed files. View all files exposes unchanged paths. Selecting an unchanged Swift file displayed its historical contents inline. |
| Git controls | Temporary repositories with a local bare remote exercised branch switching, stash, pop, push and fast-forward pull. Undo and Redo apply to a branch switch. |

The test repository has fewer commits and references than the screenshot. Hosted account, team, and issue panels are outside this local Git workspace.

## Graph label hover

Compared the supplied branch hover crop with a native TruGit window using the same current branch name and a remote release branch. The expanded badge starts at the compact label’s top-left corner. Two references occupy two 24-point rows. The checkmark, full branch name, and repository-type icon fit on one line. TruGit retains the remote prefix so the destination is visible.

Tested hover on a label, the overflow count, and the corresponding graph node. Moving away collapsed the stack without changing graph selection. Hit testing resolved the expanded local and remote rows separately. A second fixture with 19 references showed a scrollable stack.

final result: passed

An AppKit integration check opened the stack on the first hover event. It dragged the second local branch out of one stack and delivered the drop to the second branch in another. The check drove the native drag callbacks in-process and verified that Branch Actions offered merge into the destination and rebase onto the destination.
