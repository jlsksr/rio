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
  whether it has unsaved changes, its language (detected from the name, or [picked by hand](editor.md#syntax-highlighting)), the caret position as
  `Ln 12, Col 5`, and how many buffers you have open. In vi or emacs mode it also
  shows the mode's own indicator, such as `-- INSERT --`.

The **window title** shows the current file, with a `●` after the name when it has
unsaved changes. Tabs carry the same dot, so you can see at a glance which of them
still need saving.

## Right-click menus

Nearly every surface in rio answers a right-click, and what the menu holds depends
on what the surface is.

*Text you can type into* — the find and search fields, the agent's message box, the
git commit bar, the boxes in dialogs — offers **Cut**, **Copy**, **Paste** and
**Select All**. Cut and Copy are greyed when nothing is selected, Select All when
the field is empty. Paste is always offered: finding out whether the clipboard
holds anything means asking whichever application owns it, and rio would rather
offer the entry than make you wait on a program that might not answer.

*Text you can only read* — the agent's transcript, a diff, the compare panes, a
plan, the pages of this manual — offers **Copy** and **Select All**. Cut and Paste
are not greyed there, they are absent: there is nothing to change.

*Rows* get a menu about the row rather than about its text — a file in the Files
tree, a change in the git pane, an editor tab. [Files & projects](files-and-projects.md),
[git](git.md) and [the editor](editor.md#tabs) each describe their own. Search
results and the manual's contents list have none yet.

The editor's text area has the longest menu of all: undo, the find and search
commands, and the agent. See [the right-click menu](editor.md#the-right-click-menu).

Two habits hold everywhere. Right-clicking *inside* a selection keeps it, so Copy
takes the text you can see is highlighted; right-clicking anywhere else drops the
selection, and in a field you can type into the caret moves to where you pointed,
so Paste lands there. And the keyboard opens the same menu without the mouse — the
`Menu` key, the one next to the right `Ctrl` on most keyboards, or `Shift+F10`.

There is one deliberately shorter menu. The provider API-key field is drawn as
bullets, so it offers **Paste** and **Select All** only: pasting a key is what the
field is for, and lifting one back out as plain text is not, because rio treats a
key as a secret ([the agent](agent.md#your-api-key)).

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

## Help, and which rio you are running

***Help ▸ Contents…*** — or `F1` — opens this manual inside rio, formatted, from
disk, with no network.

***Help ▸ About rio*** opens a small box with rio's name, one line about what it
is, and a few facts about the copy in front of you:

| Row | What it tells you |
| --- | ----------------- |
| `Build` | which build of the window this is, taken from the source it was started from — `unknown` for a copy with no git history beside it |
| `Date` | when that build was made |
| `Protocol` | the version of the protocol this window speaks to its core |
| `License` | the licence rio is under — `MIT` |

The first three describe the build, and are the ones worth quoting in a bug
report. The last is about your copy: rio is under the MIT License, so you may use
it, change it, build on it and pass it on, as long as the copyright notice and the
licence text travel with the copies you hand out. The full text is in
[LICENSE](../LICENSE); if you are sending a change back rather than taking one
away, [CONTRIBUTING.md](../CONTRIBUTING.md) covers what the licence means for that.

## Where to go next

- [The editor](editor.md) — the text area in depth.
- [Files & projects](files-and-projects.md) — working with a folder.
- [The agent](agent.md) — putting an AI to work on your project, with you in the
  loop.
