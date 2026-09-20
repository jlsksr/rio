# Find & replace

The in-buffer find bar, the project-wide Search panel, and which one to reach for.

**This topic is still to be written.** It will cover: the find bar (`Ctrl+F`, with
`Ctrl+H` adding the replace row), live match highlighting and the match count,
`F3` / `Shift+F3` stepping with wrap-around, and match-case and whole-word
toggles; two-step Replace and Replace All as a single undo step; the Search panel
(`Ctrl+Shift+F`) and its three scopes — the whole project on disk, all open
documents including unsaved edits, or just the current document; regex patterns
with backreferences; replacing across a scope; and escalating from the find bar
into the panel with your needle and options intact.

One rule is worth knowing now, because nothing on screen announces it: searching
**the whole project on disk** skips files bigger than about 2 MB and files that
look binary — the same test the editor makes before it
[opens one](editor.md#opening-a-very-large-or-binary-file), with a smaller budget,
because a search that walks a whole tree can afford to pass over what it cannot
usefully show. Those files are skipped silently, so a word that lives only inside
a very large log will not be found. The other two scopes search documents you
already have open, whatever their size.

For now, the *Find & Replace* and *Search* entries under **What works now** in
[README.md](../README.md) describe both tools in full.

- [The editor](editor.md) — including why Replace All is one undo step.
- [Keyboard shortcuts](keyboard.md) — the find and search chords.
- [Right-click menus](getting-started.md#right-click-menus) — the editing menu the
  find bar's and the Search panel's fields carry.
