# Git

The git pane: seeing what changed, reading a diff, staging, committing and
discarding, without leaving the editor.

rio does not reimplement git. The pane runs the `git` you already have
installed and shows what it says, so a staged file is staged and a commit is a
commit — anything rio does here you could have typed yourself.

## Opening the pane

`Ctrl+Shift+G`, or ***View ▸ Git***, shows it. It shares the side panel with the
[file tree](files-and-projects.md), and like every tool pane it can be moved to
another dock site: right-click its tab and pick *Move to*.

The pane needs a **project**. Open a folder (`Ctrl+Shift+O`) whose root is a git
repository. Until then the pane says so rather than guessing, because with no
folder open git would run against whatever directory rio was launched from. If
the folder is not a repository it says *(not a git repository)*; if nothing has
changed, *(clean)*.

The header shows the current branch, `⎇ main`.

## Reading the status

Each changed file is one row. The two characters before its name are git's own
status pair, exactly what `git status --short` prints:

| Character | Means |
| --------- | ----- |
| First | What is **staged** — in the index, ready to commit. |
| Second | What is **unstaged** — changed in your working tree. |

So `M ` is staged and clean on disk, ` M` is modified but not staged, and `MM`
is both: staged once, then edited again. `A` is a new file added to the index,
`D` a deletion, `R` a rename, and `??` a file git has never been told about. The
characters are coloured by kind.

**Click a row to see its diff** below the list. A row that is staged and
otherwise clean shows the staged diff (`--cached`); anything else shows the
working-tree diff. An untracked file has no diff and says so.

A **rename** is one change with two names, and git stages it as `R`. The row can
only show the new name, so the diff is where you see the whole of it: it names
the file the change came from (`rename from old.txt`), and shows the edits too
if the move carried any.

The diff is read-only. Select in it and right-click for *Copy* to lift out a
hunk or a changed line.

The same status flags appear in the **file tree**, one character in front of
each row, so you can see what changed without switching panes. A folder carries
a `·` when something beneath it has changed.

## Staging and unstaging

Right-click a row. The menu opens with **Open** and **Copy Path**, then the git
verbs that row's status allows:

| Entry | Does | Offered when |
| ----- | ---- | ------------ |
| **Stage** | `git add` on that path | there is an unstaged change |
| **Unstage** | Takes it out of the index, leaving your edit alone | something is staged |
| **Track (git add)** | The name Stage takes on an untracked file | the file is untracked |

The file tree's row menu carries the same three, plus **Stage folder** on a
directory that contains changes.

**A brand-new folder is listed as one row.** git reports a folder none of whose
files are tracked as a single entry — `sub/` — rather than listing everything
inside it. That row has no **Open**, because it is not a file, and its stage
item reads **Stage folder**.

To add just one file out of such a folder, right-click the file in the **file
tree**, which does list it, and choose **Track (git add)**. After that first
add, git starts listing the folder's remaining files individually and they
appear in the git pane like any other change.

## Committing

The commit bar appears at the bottom of the git pane when there is something
staged, and disappears when there is not.

1. Type a summary line.
2. For a longer message, press **＋** to open a description box underneath.
3. Press **✓ Commit**.

The header briefly shows the new commit's short hash, and the bar puts itself
away.

Summary and description are joined the way git joins them: the summary becomes
the subject line, the description the body, with a blank line between.

An empty summary is refused on the spot, with the cursor left in the field.

Both fields are ordinary text boxes: right-click either for **Cut**, **Copy**,
**Paste** and **Select All**, so a message written elsewhere can be pasted
straight in. See [right-click menus](getting-started.md#right-click-menus).

rio commits what is **staged**, as git does. There is no "commit all" that
stages behind your back.

## Discarding changes

Discarding is destructive, so every door to it confirms first, the default
answer is **No**, and the dialog says what will happen to that file.

**One file**, from the row menu in the git pane or the file tree:

| Entry | On | Does |
| ----- | -- | ---- |
| ***Discard Changes…*** | a tracked file | Puts it back to the last committed version, dropping staged and unstaged changes both. |
| ***Delete…*** | a **new** file | git has never committed it, so there is no earlier version to go back to. Discarding it can only mean deleting it. |
| ***Discard Changes…*** | a **rename** | The file goes back to its old name and its last committed contents. The confirm names the old file. Only the git pane's menu words it this way, because only the pane is holding both names. |

**Everything at once:** the **↩** button in the git pane header, present only
while the repo has changes. It discards every change in the project — changed
files back to their last commit, never-committed files deleted — and the confirm
quotes the number of changes first.

**Files git ignores are left alone**, so build output, `node_modules` and your
local scratch files survive it.

None of this can be undone from rio. It is git's own `reset` and `clean`, and
once a never-committed file is gone, it is gone.

A discard is a change on disk, so the file tree repaints and any tab open on a
discarded file notices: it reloads quietly if you had nothing unsaved, and asks
if you did. See [when a file changes underneath
you](editor.md#when-a-file-changes-underneath-you).

## Over a remote core

Everything above runs where the core runs. Connected to a core on another
machine, the repository is that machine's, `git` is that machine's git, and your
commits land there. The pane looks and behaves identically, because the window
never touches the repository itself: it asks the core, exactly as it does
locally. See [working remotely](remote.md).

## What the pane does not do

Branches, history, remotes, merges and conflict resolution: no log view, no
`push`, `pull` or `fetch`, no branch switching. rio is an editor with git in it,
not a git client, and those are the operations where a terminal and the git you
already know work better.

## Further reading

- [Files & projects](files-and-projects.md) — the other half of the same side
  panel.
- [The editor](editor.md#comparing-two-documents) — the side-by-side compare
  view.
- [The agent](agent.md) — it can read your project and propose edits, and it can
  run `git` as a command, but only through the approval gate.
