# Find & replace

The find bar for the file you are in, the Search panel for a whole project, and
which one to reach for.

| Tool | Key | Searches |
| ---- | --- | -------- |
| Find bar | `Ctrl+F` | the current file, highlighting matches as you type |
| Search panel | `Ctrl+Shift+F` | the whole project on disk, all open files, or just the current one |

**This topic is still to be written.** It will cover: the find bar, with
`Ctrl+H` adding the replace row, live highlighting and the match count, `F3` and
`Shift+F3` stepping with wrap-around, and the match-case and whole-word
toggles; two-step Replace, and Replace All as a single undo step; the Search
panel and its three scopes; regex patterns with backreferences; replacing across
a scope; and escalating from the find bar into the panel with your search text
and options intact.

Until then, the *Find and replace* and *Project search* entries in
[README.md](../README.md) summarise both tools.

## One rule nothing on screen tells you

Searching **the whole project on disk** skips files bigger than about 2 MB and
files that look binary — the same test the editor makes before it
[opens one](editor.md#opening-a-very-large-or-binary-file), with a smaller
limit, because a search that walks a whole tree can afford to pass over what it
cannot usefully show.

Those files are skipped silently, so a word that lives only inside a very large
log will not be found. The other two scopes search files you already have open,
whatever their size.

## Further reading

- [The editor](editor.md#undo-and-redo) — why Replace All is one undo step.
- [Keyboard shortcuts](keyboard.md) — the find and search chords.
- [Right-click menus](getting-started.md#right-click-menus) — the editing menu
  the find bar's and the Search panel's fields carry.
