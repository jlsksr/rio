# Getting started

Starting rio, the parts of the window, and your first edit.

Install rio first: [INSTALL.md](../INSTALL.md), or [WINDOWS.md](../WINDOWS.md)
for Windows.

## Start rio

After an install script has run, rio is in your application menu (on Windows,
the Start Menu and the Desktop; on a Mac, where `install-macos.sh` puts it in
`~/Applications`, Spotlight and the Dock), and `rio` is a command:

```sh
rio                        # an empty tab
rio notes.txt draft.md     # those files, one tab each
rio ~/src/myproject        # that folder as a project
```

Without the launcher (a bare checkout, or `--no-launcher`), use
`wish rio-gui/rio-gui.tcl` with the same arguments. The `rio` command is a small
wrapper around exactly that.

Nothing needs starting first. rio's logic runs in a separate program, the
**core**. The window starts its own private copy as a child process and stops it
again when you quit. The core only matters when you want to edit files on
another machine: see [working remotely](remote.md).

**Open a folder, not only files,** if you want the file tree, the git pane,
project-wide search, and your open files back next time. A folder opened this
way is a *project*.

## The window

| Part | What it is |
| ---- | ---------- |
| Menu bar | *File*, *Edit*, *View*, *Find*, *Compare*, *Settings*, *Extensions*, *Help*. Each item shows its keyboard shortcut, and relabels itself if you remap it. *Settings* is what rio itself does; *Extensions* installs what you add, and opens the settings of anything you have added. |
| Side panel | The **Files** tree and the **Git** pane share one column. `Ctrl+Shift+E` shows Files, `Ctrl+Shift+G` shows Git. Dock it left or right from ***View ▸ Dock Side***, or drag its edge to resize it. |
| Editor | Your open files, as tabs. `Ctrl+\` splits it into two groups side by side, each with its own tabs. |
| Agent column | The chat pane on the right. `Ctrl+Shift+A` shows and hides it. See [the agent](agent.md). |
| Status bar | The bottom strip. It describes the file you are in: path, text encoding, line endings (`lf` or `crlf`), whether it has unsaved changes, its language, the caret position as `Ln 12, Col 5`, and how many files you have open. In vi or emacs mode it also shows that mode's indicator, such as `-- INSERT --`. |

The window title shows the current file, with a `●` after the name when it has
unsaved changes. Tabs carry the same dot.

The language in the status bar is detected from the file name. To set it
yourself, use [syntax highlighting](editor.md#syntax-highlighting).

## Right-click menus

What a right-click offers depends on what you click.

*Text you can type into* — the find and search fields, the agent's message box,
the git commit bar, the boxes in dialogs — offers **Cut**, **Copy**, **Paste**
and **Select All**. Cut and Copy are greyed out when nothing is selected, Select
All when the field is empty. Paste is always available.

*Text you can only read* — the agent's transcript, a diff, the compare panes, a
plan, this manual — offers **Copy** and **Select All**. Cut and Paste are not
there at all, because there is nothing to change.

*Rows* get a menu about the row rather than about its text: a file in the Files
tree, a change in the git pane, an editor tab. See
[files & projects](files-and-projects.md), [git](git.md) and
[the editor](editor.md#tabs). Search results and the manual's contents list have
no row menu yet.

The editor's text area has the longest menu: undo, the find and search commands,
and the agent. See [the right-click menu](editor.md#the-right-click-menu).

Two rules hold everywhere:

- Right-click *inside* a selection and the selection stays, so Copy takes what
  you can see is highlighted. Right-click anywhere else and the selection is
  dropped; in a field you can type into, the caret moves to where you pointed,
  so Paste lands there.
- The `Menu` key (next to the right `Ctrl` on most keyboards) and `Shift+F10`
  open the same menu without the mouse.

The provider API-key field is shown as bullets, so its menu is shorter. It
offers **Paste** and **Select All** only: you can put a key in, but not lift
one out as plain text. See [your API key](agent.md#your-api-key).

## Make your first edit

1. Press `Ctrl+N` for a new empty tab, or `Ctrl+O` to open a file.
2. Type. The keys behave as they do in Notepad and VS Code: `Ctrl+A` selects
   all, `Ctrl+C` and `Ctrl+V` copy and paste, `Ctrl+Z` undoes. For vi or emacs
   keys instead, see [editing modes](editing-modes.md).
3. Press `Ctrl+S` to save, or `Ctrl+Shift+S` to save under a new name.

## What rio will not do to your file

**It does not rewrite your file silently.** rio records the text encoding and
the line endings a file arrived with and writes them back unchanged. A CRLF file
saved on Linux stays CRLF; a UTF-8 file stays UTF-8. The status bar shows both.

**It does not save for you.** Nothing reaches your file until you ask. rio does
keep a *separate* copy of your unsaved changes every 30 seconds and offers it
back the next time you open that file, so a crash costs you at most that much.
See [keeping your unsaved changes](editor.md#keeping-your-unsaved-changes).

## A few things to know early

- **Undo works in words, not keystrokes.** `Ctrl+Z` takes back a word rather
  than a letter. [The editor](editor.md#undo-and-redo) says where a step ends.
- **`Ctrl+F` searches the current file; `Ctrl+Shift+F` searches the whole
  project.** Two tools for two jobs: see [find & replace](find-and-replace.md).
- **Every shortcut can be remapped**, in ***Settings ▸ Keyboard Shortcuts…*** or
  by hand. The defaults are in [keyboard shortcuts](keyboard.md).
- **Settings save themselves.** Change a theme or turn on line wrap and it is
  your default from then on. There is no "save settings" step. See
  [preferences](preferences.md).

## Help, and which rio you are running

***Help ▸ Contents…*** (`F1`) opens this manual inside rio.

***Help ▸ About rio*** shows the name, one line about what rio is, and these
facts about the copy in front of you:

| Row | What it tells you |
| --- | ----------------- |
| `Version` | which release of rio this is |
| `Build` | which build of the window this is, from the source it was started from — `unknown` for a copy with no git history beside it |
| `Date` | when that build was made |
| `Protocol` | the version of the protocol this window speaks to its core |
| `License` | the licence rio is under — `MIT` |

Quote both `Version` and `Build` in a bug report. Version names the release,
which is what a changelog is written against. Build names the exact commit
under it, which between releases is the precise one. If you are connected to a
core on another machine (***File ▸ Connect to Remote Core…***) and that core is
a different release, the Version row names both: the window's, then the
core's in brackets.

rio is on `0.x` on purpose: early days, and things may still change between
releases.

You can also ask without opening the window. `rio --version`,
`rio-gui.tcl --version` and `rio-core/server.tcl --version` all print it and
exit.

Under the MIT License you may use rio, change it, build on it and pass it on, as
long as the copyright notice and the licence text travel with the copies you
hand out. The full text is in [LICENSE](../LICENSE). To send a change back
instead, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Next

- [The editor](editor.md) — the text area in depth.
- [Files & projects](files-and-projects.md) — working with a folder.
- [The agent](agent.md) — putting an AI to work on your project, with you in the
  loop.
