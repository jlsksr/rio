# Files & projects

The file tree, opening a folder as a project, creating and renaming files, and
how rio brings your open files back.

**This topic is still to be written.** It will cover: opening a folder
(`Ctrl+Shift+O`) and what makes it a *project*; the Files pane as a tree you
unfold in place, and showing hidden files; creating, renaming and deleting files
and folders from the row menu; how the tree keeps itself current; dragging a
file in from your file manager; and sessions — the open files and active tab
that come back when you reopen a project.

Until then, the *Files and git* and *Sessions* entries in
[README.md](../README.md) summarise it, and
[preferences](preferences.md#where-everything-lives) says where session state is
kept.

## Three things that are documented elsewhere

**Refreshing.** The tree repaints when rio itself writes to disk, when rio
regains focus, and when you press the `⟳` button. It does not watch the
filesystem continuously, so a change made by another program while you sit in
rio is noticed when you come back to the window.

**Files that ask before opening.** A file over 64 MB, or one that looks like a
binary rather than text, is confirmed with a yes/no question first — including
files a session reopens for you. See [opening a very large or binary
file](editor.md#opening-a-very-large-or-binary-file).

**Unsaved changes from last time.** If rio stopped while some files had unsaved
changes, it kept a copy of each and offers the whole set back in one question
once the project is open. See [keeping your unsaved
changes](editor.md#keeping-your-unsaved-changes).

Rows in a git repository also carry their git status, and their row menu the git
verbs that go with it, including *Discard Changes…*. See [git](git.md).

## Further reading

- [Getting started](getting-started.md) — the window, and what the side panel
  is.
- [Git](git.md) — the other half of the same side panel.
