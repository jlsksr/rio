# Files & projects

The file tree, opening a folder as a project, creating and renaming files, and how
rio brings your open files back the next time.

**This topic is still to be written.** It will cover: opening a folder
(`Ctrl+Shift+O`) and what makes it a *project*; the Files pane as an unfoldable
tree, folding and unfolding, and showing hidden files; creating, renaming and
deleting files and folders from the row menu; how the tree keeps itself current
(it repaints whenever rio itself writes to disk, when rio regains OS focus, and on
the ⟳ button — it does not watch the filesystem continuously); dragging a file in
from your OS file manager; and sessions — the open files and active tab that come
back when you reopen a project.

Opening a file from the tree is not always instant and silent: a file over 64 MB,
or one that looks like a binary rather than text, is confirmed with a yes/no
question first — including the files a session reopens for you. That half is
documented in [the editor](editor.md#opening-a-very-large-or-binary-file).

Rows in a git repository also carry their **git status**, and their row menu the
git verbs that go with it — including *Discard Changes…*, so undoing your edits to
a file is reachable from wherever you happen to be looking at it. That half is
documented in [git](git.md).

For now, the *Files & git* and *Sessions* entries under **What works now** in
[README.md](../README.md) describe the rest, and
[preferences](preferences.md#where-everything-lives) says where session state is
kept on disk.

- [Getting started](getting-started.md) — the window, and what the side panel is.
- [Git](git.md) — the other half of the same side panel.
