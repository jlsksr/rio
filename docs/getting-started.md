# Getting started

Your first few minutes with rio: how to launch it, what each part of the window
is, and how to make and save an edit.

If rio isn't installed yet, [INSTALL.md](../INSTALL.md) covers that — on Windows,
[WINDOWS.md](../WINDOWS.md) does it in one script.

## Launching

Run the GUI directly:

```
wish rio-gui/rio-gui.tcl
```

You can hand it files to open, a folder to work in, or both:

```
wish rio-gui/rio-gui.tcl notes.txt draft.md
wish rio-gui/rio-gui.tcl ~/src/myproject
```

**There is nothing to start first.** rio's logic lives in a separate program — the
*core* — and the window starts its own private copy automatically, as a child
process, and stops it again when you quit. You only think about the core when you
want to edit files on **another machine**; see [Working remotely](remote.md).

Opening a **folder** rather than loose files makes it a *project*: the file tree,
the git pane, and project-wide search all work against it, and rio remembers which
files you had open the next time you open that folder.

## The window

From the top down:

- **The menu bar** — *File*, *Edit*, *View*, *Find*, *Compare*, *Settings*,
  *Help*. Everything rio can do is reachable here, with its keyboard shortcut
  shown beside it. If you remap a shortcut, the menu relabels itself to match.
- **The side panel** — the **Files** tree and the **Git** pane share one dockable
  column. `Ctrl+Shift+E` reveals Files, `Ctrl+Shift+G` reveals Git. You can dock
  it left or right from *View ▸ Dock Side*, or drag its edge to resize it.
- **The editor** — one or more open buffers as **tabs**. `Ctrl+\` splits it into
  two independent groups side by side, each with its own tabs.
- **The agent column** — the chat pane on the right, toggled with
  `Ctrl+Shift+A`. See [the agent](agent.md).
- **The status bar** — the bottom strip, which always tells you about the buffer
  you are in: its path, its text encoding, its line endings (`lf` or `crlf`),
  whether it has unsaved changes, its detected language, the caret position as
  `Ln 12, Col 5`, and how many buffers you have open. In vi or emacs mode it also
  shows the mode's own indicator, such as `-- INSERT --`.

The **window title** shows the current file, with a `●` after the name when it has
unsaved changes. Tabs carry the same dot, so you can see at a glance which of them
still need saving.

## Your first edit

1. `Ctrl+N` opens a new empty tab, or `Ctrl+O` opens a file.
2. Type. The text area behaves the way Notepad and VSCode do out of the box —
   `Ctrl+A` selects all, `Ctrl+C`/`Ctrl+V` copy and paste, `Ctrl+Z` undoes. If you
   would rather have vi or emacs keys, see [editing modes](editing-modes.md).
3. `Ctrl+S` saves. `Ctrl+Shift+S` saves under a new name.

**rio does not silently rewrite your file.** It records the encoding and the line
endings a file arrived with and writes them back unchanged, so opening a CRLF file
on Linux and saving it does not turn it into an LF file, and a UTF-8 file stays
UTF-8. The status bar shows both, so you can always see what will be written.

## Getting your bearings

A few things worth knowing early:

- **Undo works in words, not keystrokes.** A run of typing collapses into one undo
  step, so `Ctrl+Z` takes back a word rather than a letter. [The editor](editor.md)
  explains exactly where a step ends.
- **`Ctrl+F` finds in the current buffer; `Ctrl+Shift+F` searches the whole
  project.** They are two different tools for two different jobs — see
  [find & replace](find-and-replace.md).
- **Every shortcut is remappable**, in *Settings ▸ Keyboard Shortcuts…* or by hand.
  The full default list is in [keyboard shortcuts](keyboard.md).
- **Settings save themselves.** Flip a theme or turn on line wrap and it is your
  default from then on — there is no separate "save settings" step. See
  [preferences](preferences.md).

## Where to go next

- [The editor](editor.md) — the text area in depth.
- [Files & projects](files-and-projects.md) — working with a folder.
- [The agent](agent.md) — putting an AI to work on your project, with you in the
  loop.
