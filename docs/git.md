# Git

The git pane: seeing what changed, reading a diff, staging, committing, and
discarding — without leaving the editor.

rio does not reimplement git. The pane runs the `git` you already have installed
and shows you what it says, so nothing here is a rio-flavoured version of a git
concept: a staged file is staged, a commit is a commit, and anything rio does you
could have typed yourself.

## Opening the pane

`Ctrl+Shift+G` reveals it, as does ***View ▸ Git***. It shares the side panel with
the [file tree](files-and-projects.md), and like every tool pane it can be moved to
another dock site — right-click its tab and pick *Move to*.

The pane needs a **project**: open a folder (`Ctrl+Shift+O`) whose root is a git
repository. Until then it says so rather than guessing — with no folder open, git
would run against whatever directory rio itself was launched from, which is never
what you meant. If the folder is not a repository it says *(not a git repository)*,
and if nothing has changed, *(clean)*.

The header shows the current branch, `⎇ main`.

## Reading the status

Each changed file is one row, and the two characters before its name are git's own
status pair — exactly what `git status --short` prints:

| | Means |
| --- | ----- |
| first character | what is **staged** (in the index, ready to commit) |
| second character | what is **unstaged** (changed in your working tree) |

So `M ` is staged and clean on disk, ` M` is modified but not staged, and `MM` is
both — staged once, then edited again. `A` is a new file added to the index, `D` a
deletion, `R` a rename, and `??` a file git has never been told about. The
characters are coloured by kind: additions one colour, deletions another,
modifications a third.

**Click a row to see its diff** below the list. A row that is staged and otherwise
clean shows the staged diff (`--cached`); anything else shows the working-tree
diff — in both cases, the change the row's status is actually describing. An
untracked file has no diff to show and says so.

A **rename** — from `git mv`, or from moving a tracked file any other way — is one
change with two names, and git stages it as `R`. The pane's row can only show the
new name, so the diff is where you see the whole of it: it names the file the
change came from (`rename from old.txt`), and shows the edits too if the move
carried any.

The same status flags appear in the **file tree**, one character in front of each
row, so you can see which files changed without switching panes. A folder carries
a `·` when something beneath it has changed.

## Staging and unstaging

Right-click a row. It opens with **Open** and **Copy Path**, and then the git verbs
that its status actually allows:

- **Stage** — `git add` on that path. Offered when there is an unstaged change.
- **Unstage** — takes it back out of the index, leaving your edit alone. Offered
  when something is staged.
- **Track (git add)** — the name Stage takes on an untracked file, because the
  first `git add` on a file does something different from all the later ones.

The file tree's row menu carries the same three, plus **Stage folder** on a
directory that contains changes.

**A brand-new folder is listed as one row.** git reports a folder none of whose
files are tracked as a single entry — `sub/` — rather than listing everything
inside it, so the git pane shows one row for the whole folder. That row has no
**Open** (it is not a file) and its stage item reads **Stage folder**, because it
stages everything under it.

To add just *one* file out of such a folder, right-click the file in the **file
tree**, which lists it: it offers **Track (git add)**. After that first add, git
starts listing the folder's remaining files individually, and they appear in the
git pane like any other change.

## Committing

The **commit bar** appears at the bottom of the git pane exactly when there is
something staged to commit, and disappears when there isn't. Type a summary line
and press **✓ Commit**. The header briefly shows the new commit's short hash, and
the bar puts itself away — there is nothing staged any more.

For a longer message, the **＋** button opens a description box under the summary.
Summary and description are joined the way git joins them — the summary becomes the
commit's subject line, the description its body, with the blank line between them
that every git tool expects.

An empty summary is refused on the spot, with the cursor left in the field; rio
would rather say so than let git abort the commit for you.

rio commits what is **staged**, like git does. There is no "commit all" shortcut
that stages behind your back.

## Discarding changes

Discarding is the destructive one, so every door to it confirms first, the default
answer is **No**, and the dialog says exactly what will happen to that file.

**One file**, from the row menu in either the git pane or the file tree:

- ***Discard Changes…*** on a tracked file — it goes back to the last committed
  version, staged and unstaged changes both dropped.
- ***Delete…*** on a **new** file — one git has never committed, so there is no
  earlier version to go back to. Discarding it can only mean deleting it, and the
  menu says the true word. (In the file tree this entry is just the tree's own
  *Delete…*, which already removes the file.)
- ***Discard Changes…*** on a **rename** — the file goes back to its **old name**
  and its last committed contents. The confirm names the old file, because
  otherwise the file vanishing from the tree under the name you right-clicked would
  read as a deletion. Only the git pane's menu can word it this way: git reports a
  rename as one change with two names, and only the pane is holding both.

**Everything at once**: the **↩** button in the git pane header, which is present
only while the repo has changes. It discards every change in the project — changed
files back to their last commit, never-committed files deleted — and the confirm
quotes the number of changes first. **Files git ignores are left alone**, so build
output, `node_modules` and your local scratch files survive it.

None of this can be undone from rio. It is git's own `reset` and `clean`, and once
a never-committed file is gone, it is gone.

> **A discard is a change on disk, and rio treats it as one.** The file tree
> repaints, and any tab open on a discarded file notices that its file moved
> underneath it — reloading quietly if you had nothing unsaved, asking if you did.
> See [when a file changes underneath you](editor.md#when-a-file-changes-underneath-you).

## Over a remote core

Everything above runs **where the core runs**. Connected to a core on another box,
the repository is that box's repository, `git` is that box's git, and your commits
land there — the pane looks and behaves identically. Nothing about the git pane
needs a local checkout, because the GUI never touches the repository itself; it
asks the core, exactly as it does locally. See [working remotely](remote.md).

## What is not here yet

The pane covers the daily loop — see what changed, stage it, commit it, throw
something away. It does **not** do branches, history, remotes, merges or conflict
resolution: no log view, no `push`/`pull`/`fetch`, no branch switching. That is a
choice rather than a gap: rio is an editor with git in it, not a git client, and
those are the operations where a terminal and the git you already know are better
than a small pane guessing at what you meant.

## Further reading

- [Files & projects](files-and-projects.md) — the other half of the same side panel.
- [The editor](editor.md#comparing-two-documents) — the side-by-side compare view.
- [The agent](agent.md) — it can read your project and propose edits, and it can run
  `git` as a command, but only ever through the approval gate.
