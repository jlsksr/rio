# The editor

The text area and what surrounds it: tabs, undo, the split view, wrap, line
numbers, syntax highlighting, column editing, the compare view, and what happens
to changes you have not saved.

## Tabs

Each open file is a tab.

| Key | Does |
| --- | ---- |
| `Ctrl+N` | New empty tab |
| `Ctrl+O` | Open a file |
| `Ctrl+W` | Close the current tab |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous tab |

A tab with unsaved changes carries a `●` after its name.

Drag a tab sideways to reorder it, or onto the other editor group to move it
there. Its right-click menu does the same without dragging.

**When there are more tabs than fit:**

- The `◂ ▸` arrows page through the strip, one screenful at a time. This is the
  default.
- ***View ▸ Multi-Line Tabs*** wraps the strip onto as many rows as it needs, so
  every tab is visible.
- ***View ▸ Switch to Tab…*** lists every open file in one picker, with a path
  hint so two files of the same name can be told apart. It is also on the
  *Compare* menu.

## Splitting the editor

`Ctrl+\` splits the editor into two groups side by side, each with its own tabs
and its own caret. Drag the divider to resize them. `Ctrl+]` moves the current
tab to the other group. Closing a group's last tab unsplits.

Use the split to *edit* two files at once. To *compare* two files, use
[the compare view](#comparing-two-documents) instead.

## Undo and redo

`Ctrl+Z` undoes. `Ctrl+Shift+Z` or `Ctrl+Y` redoes.

**Undo works a word at a time, not a keystroke at a time.** Type `hello world`,
press `Ctrl+Z`, and `world` goes, not just the `d`.

A run of typing keeps growing into one undo step until one of these ends it:

| What you do | Effect on the step |
| ----------- | ------------------ |
| Type a space | The space joins the word; the next character starts a new step. |
| Press Enter | A newline is always its own step. |
| Move the caret | Clicking or arrowing away starts a new step. |
| Switch between typing and deleting | Deletions merge with deletions, never with the typing before them. |
| Paste, Replace All, an agent edit, a vi operator | Each is one step already. It neither joins a run nor lets one continue. |

Backspace and Delete coalesce the same way, each in its own direction: hold
Backspace through a word and one `Ctrl+Z` brings the word back.

Undo history belongs to the file, not to the view, so it survives switching tabs
and moving a tab to the other group. You can undo past your last save; the `●`
marker tells you whether what is on screen matches the disk.

History is bounded. After a very long session in one file the oldest steps drop
off, and undo stops earlier. The last edit can always be undone, whatever its
size.

> **In vi mode** the granularity is vi's. Pressing `x` three times gives three
> separate undos, but a whole insert session (`i`, type a word, `Esc`) comes
> back with one `u`. See [editing modes](editing-modes.md).

## The right-click menu

Right-clicking the text offers **Undo** and **Redo**, then **Cut**, **Copy** and
**Paste**, then **Select All**, then **Find…**, **Replace…** and **Search…**.

With a real agent provider selected (any provider but Echo), one more entry
comes last: **Change with Agent…**, which asks the agent to change the selected
text and nothing else. See
[changing just the selection](agent.md#changing-just-the-selection). It is
absent with Echo, and *Preferences ▸ Agent ▸ "Show “Change with Agent…” in
the editor's context menu"* hides it for good.

Where you click decides what the menu acts on:

- *Inside a selection* — the selection stays, so Cut, Copy, the search entries
  and Change with Agent… act on the highlighted text.
- *Anywhere else* — the selection is dropped and the caret moves to where you
  pointed, so Paste lands there.

With a word or phrase selected, the Search entry names it (*Search for
“needle”*) and opens the [project-wide search](find-and-replace.md) already
filled in. Find and Replace seed themselves from the selection too. A selection
spanning several lines seeds nothing, and the entry goes back to its plain name.

Entries you cannot use are greyed out: Cut and Copy with nothing selected,
Select All in an empty file, Change with Agent… with nothing selected or while
an agent turn is working or waiting for you. Undo and Redo are always offered,
whether or not there is anything left to undo.

The `Menu` key and `Shift+F10` open the same menu at the caret. It works the
same in every [editing mode](editing-modes.md), vi included. The other text
surfaces have shorter menus: see
[right-click menus](getting-started.md#right-click-menus).

## Line wrap

***View ▸ Wrap Lines*** (`Ctrl+Shift+W`) wraps long lines to the window width
instead of scrolling sideways. Nothing in the file changes and no line break is
inserted.

***View ▸ Indent Wrapped Lines*** puts the continuation rows of a wrapped line
under that line's own indentation instead of hard against the left margin. It
only matters while wrap is on.

## Line numbers and the current line

| Menu item | Does |
| --------- | ---- |
| ***View ▸ Line Numbers*** (`Ctrl+L`) | Shows the gutter. On by default. Click a number to select the whole line. |
| ***View ▸ Relative Line Numbers*** | Numbers every other line by its distance from the caret, which is the count a vi motion such as `12k` wants. The caret's own line keeps its real number. |
| ***View ▸ Highlight Current Line*** | Tints the line the caret is on, per editor group, so a split shows which side has focus. |

## Font and zoom

***View ▸ Font & Zoom ▸ Font…*** sets the document font family and size.
`Ctrl+scroll`, `Ctrl++` and `Ctrl+-` zoom; `Ctrl+0` resets. Your choice is kept,
and overrides whatever the theme would have used.

This is the document font only. Menus and dialogs keep the system font, so
zooming in on code does not reflow the whole window.

## Syntax highlighting

rio chooses a highlighter from the **file name**, in this order:

1. The whole name, for build files that carry no extension — `Makefile`,
   `Dockerfile`.
2. The extension — `.tcl`, `.py`, `.json`.
3. The name without its last extension, so `Dockerfile.prod` and `Makefile.inc`
   still count.

Case is ignored. rio never looks inside the file: a `#!` line or an editor
modeline changes nothing. A name that matches nothing, and a new tab with no
name, stay plain text. Saving under a new name, or renaming the file in the
Files pane, picks again at once. The status bar shows the language in use.

**To set the language yourself**, for code pasted into a new tab or a script
with no extension, use ***View ▸ Language…***. It lists:

- **Auto-detect**, with what the file name would give in brackets;
- **Plain Text**, no highlighting;
- every language rio has, including highlighters you have
  [installed](extensions.md).

The list opens on the current choice. It applies to that one file, and it sticks
through a save under another name or a rename until you choose Auto-detect
again. It is not remembered when rio restarts. If you remove the extension that
provided the language, the file goes back to detection.

## Column (block) editing

Off by default. Turn it on in ***Settings ▸ Column Editing***.

Then hold `Ctrl+Shift` and drag a vertical cursor down through several lines.
Typing, Backspace, Delete and Tab act at that column on every line at once, and
the whole thing is one undo step. Drag a *width* as well as a height and typing
overwrites the rectangle you selected.

This is Notepad++'s behaviour. It is off by default because `Ctrl+Shift`+drag is
an ordinary selection gesture for anyone who does not use it.

## Comparing two documents

The *Compare* menu replaces the editor with a side-by-side diff: original left,
other version right, added and removed lines coloured and kept aligned.

| Menu item | Compares the current file with |
| --------- | ------------------------------ |
| ***Compare ▸ Compare With Another Tab…*** | another open file |
| ***Compare ▸ Compare With A File…*** | any file on disk |

`Esc`, or ***Compare ▸ Close Compare***, returns you to editing.

Both panes are read-only. You can select in either and copy out of it, from the
keyboard or by [right-click](getting-started.md#right-click-menus). The
[agent](agent.md) opens complex proposed edits in this same view.

## Opening a very large or binary file

Most files just open. Two kinds are confirmed first.

**Too large** — bigger than 64 MB (67,108,864 bytes):

> core.dump is 1.2 GB — large enough that opening it may make rio slow to
> respond. Open it anyway?

**Not text** — a core dump, a database, a compiled program:

> a.out looks like a binary file rather than text (10.4 MB). Open it anyway?

Answer **no** and nothing opens: no tab, no file loaded. Answer **yes** and the
file opens, and it may genuinely be slow to appear and to edit.

A file you open anyway starts as **Plain Text**. Highlighting colours only what
is on screen, but it has to read the file from the top to know how to colour
it, and on a file this size that read is slow. If the file turns out to be
fine, ***View ▸ Language…*** turns highlighting back on: see
[syntax highlighting](#syntax-highlighting).

Every way of opening a file asks: the Files pane, ***File ▸ Open…***, a path on
the command line, a file dragged in from your file manager, and the files a
session reopens. The answer is not remembered, so a saved session does not
reload yesterday's core dump at every launch.

"Looks binary" is judged from the first 8 KB: a NUL byte in there and rio calls
it binary. The check runs before every open, so it has to be cheap. A file that
only turns binary further in opens without a question.

## Encoding and line endings

rio reads a file's text encoding and line endings and writes back exactly what
it found. An LF file stays LF on Windows, a CRLF file stays CRLF on Linux, and a
UTF-8 file is not re-encoded. Both are shown in the status bar.

There is no "convert line endings" command yet. When it arrives it will be an
explicit action, not a side effect of saving.

## Keeping your unsaved changes

**rio never writes the file you are editing without a save.** What it writes on
its own is a *separate recovery copy*, so that losing the process to a crash or
a power cut costs you at most one copy's worth of typing. Your file is still
exactly what you last saved.

Every 30 seconds, each open file you have changed since the last copy gets one.
A copy is deleted as soon as it is spent: when you **save** that file, **close**
its tab, **reload** it from disk, or **rename** it or save it under another
name. A file that has never been saved (a `Ctrl+N` tab with no name) gets no
copy, because there is nothing to offer it back against.

### Getting the changes back

The next time you open a file that has a copy waiting, rio asks:

> “notes.md” has unsaved changes that rio kept when it last stopped — newer than
> what is on disk.
>
> Take them back? The file itself is not touched, and this can be undone.

| Answer | What happens |
| ------ | ------------ |
| Yes | The tab's text becomes the copy's, marked unsaved. Nothing has reached disk; `Ctrl+S` still commits it. It arrives as a single undo step, so `Ctrl+Z` puts the file's own text back. |
| No | The copy is left alone, not deleted. Closing that tab does delete it. |

Reopening a project asks about all its files in one question, not one per file.

**A copy can be older than the file**, and rio says so in capitals. That means
something wrote the file after rio kept your copy: a `git pull`, a
`git checkout`, another editor. The copy may hold work the file never had.
That question defaults to **no**; a newer copy defaults to **yes**.

### Where the copies are kept

Outside your project, in rio's own data directory, on the machine running the
**core**. Over a [remote core](remote.md) that is the server, beside the files
themselves. Your file's path is mirrored underneath, with emacs's `#name#`
spelling:

```
/home/you/notes/todo.md
  → ~/.local/share/rio/autosave/home/you/notes/#todo.md#
```

Keeping them out of your project means they never show up in `git status`, need
no `.gitignore` entry, and cannot be committed by accident. `ls -R` over that
directory lists what you have left unsaved and where it belongs.

A copy carries the file's own encoding, byte-order mark and line endings, so
what you get back is what a save would have written.

rio never tidies these up. A copy for a file you never open again stays until
you delete it.

### Turning it off

***Preferences ▸ Editor ▸ Keep recovery files for unsaved changes*** — on by
default, and the only place to change it. It belongs to the **core**, not to the
window, because the copies land on the core's disk; see
[preferences](preferences.md#recovery-files-for-unsaved-changes) for its file
and the one setting in it you can only change by hand.

Turning it off stops new copies. Copies already written are still offered back
when you open the file, and are still deleted when you save.

## When a file changes underneath you

Files move under an editor all the time: a `git pull`, a build, a discard from
the [git pane](git.md), another window. rio checks its open tabs when one of its
own writes lands, and again when you switch back to the rio window.

| Your tab | What rio does |
| -------- | ------------- |
| No unsaved edits | Reloads from disk, quietly. It is one undo step, so `Ctrl+Z` puts back what you were looking at. |
| Unsaved edits | Asks first, defaulting to *no* — keep what you typed. Answer no and rio stops asking about that version; a later change asks again. |
| File deleted | Asks whether to keep it open. Keep it and the tab stays, marked unsaved, because your copy is the only one left — saving recreates the file. Decline and the tab closes. |

rio does not watch the filesystem continuously. A change made while you sit in
rio is noticed the next time rio writes something itself, or when you leave and
come back.

## Further reading

- [Keyboard shortcuts](keyboard.md) — the default chords, and remapping.
- [Editing modes](editing-modes.md) — vi and emacs keys in the text area.
- [Find & replace](find-and-replace.md) — searching this file or the project.
- [Panels & layout](panels-and-layout.md) — themes, docking, and the tool panes.
