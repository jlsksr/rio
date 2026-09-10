# The editor

The text area and everything around it: tabs, undo, the split view, line wrap,
line numbers, column editing, and the side-by-side compare view.

## Tabs

Each open buffer is a tab. `Ctrl+N` makes an empty one, `Ctrl+O` opens a file,
`Ctrl+W` closes the current tab, and `Ctrl+Tab` / `Ctrl+Shift+Tab` step through
them. A tab whose buffer has unsaved changes carries a `●` after its name.

**Drag a tab** to reorder it, or drag it onto the other editor group to move it
there. Its right-click menu does the same things without the dragging.

When the window is too narrow to show every tab, rio does not shrink them into
illegibility. You get two ways out:

- **◂ ▸ arrows** page through the strip one screenful at a time — the default.
- ***View ▸ Multi-Line Tabs*** wraps the strip onto several rows instead, so
  every tab is visible at once.

And when you know the name but not the position, ***View ▸ Switch to Tab…***
(also on the `Compare` menu) lists every open buffer in one picker, with a path
hint so two files of the same name are easy to tell apart.

## Splitting the editor

`Ctrl+\` splits the editor into **two groups side by side**, each with its own
tabs and its own caret. Drag the divider to resize them. `Ctrl+]` moves the
current tab across to the other group; closing a group's last tab unsplits
automatically.

The split is for *editing* two things at once. To *compare* two things, use the
compare view below — it is a different tool.

## Undo and redo

`Ctrl+Z` undoes, `Ctrl+Shift+Z` or `Ctrl+Y` redoes.

**Undo works a word at a time, not a keystroke at a time.** Typing `hello world`
and pressing `Ctrl+Z` takes back `world`, not just the `d`. This is the behaviour
VSCode and most modern editors have, and it is what makes undo usable: a
keystroke-at-a-time history would need thirty presses to take back a sentence.

A run of typing keeps growing into one undo step until something ends it. A step
ends when:

- **you type a space** — the space joins the word you just typed, and the next
  character starts a fresh step;
- **you press Enter** — a newline is always its own step, so undo never eats a
  line break you meant to keep;
- **you move the caret** — click elsewhere, or use an arrow key, and the next
  character is no longer adjacent to the last one, so it starts a new step;
- **you switch between typing and deleting** — a run of Backspace merges with
  other deletions, never with the typing before it;
- **anything that isn't a single character happens** — a paste, a Replace All, an
  agent edit, a vi operator. These are each **one step already**, and they neither
  join a run nor let one continue through them.

Backspace and Delete coalesce the same way, each in its own direction: holding
Backspace through a word takes the whole word back with one `Ctrl+Z`, and holding
Delete does the same forwards.

Undo history belongs to the **buffer**, not to the view — so it survives switching
tabs, moving a tab to the other group, and (with a project open) is per-document
exactly as you would expect. Undoing past the point where you last saved is
allowed; the `●` marker tells you whether what's on screen matches the disk.

> **In vi mode** the granularity is vi's, not this one. Pressing `x` three times
> gives you three separate undos, because in vi each command is a unit; but a
> whole insert session — `i`, type a word, `Esc` — comes back in one `u`, which is
> also what vi does. See [editing modes](editing-modes.md).

## Line wrap

***View ▸ Wrap Lines*** (`Ctrl+Shift+W`) wraps long lines to the window width
instead of scrolling sideways. Wrapping is a *view* setting: it changes nothing in
the file, and never inserts a line break.

***View ▸ Indent Wrapped Lines*** decides where the continuation rows of a wrapped
line begin — under the line's own indentation (easier to read in code), or hard
against the left margin. It only matters while wrap is on.

## Line numbers and the current line

***View ▸ Line Numbers*** (`Ctrl+L`) shows the gutter, on by default.
**Click a number to select its whole line.**

***View ▸ Relative Line Numbers*** switches the gutter to vim's hybrid style: the
current line shows its real number, and every other line shows its distance from
it — which is exactly the count a vi motion like `12k` wants.

***View ▸ Highlight Current Line*** bands the line the caret is on, per editor
group, so a split doesn't leave you guessing which side has focus.

## Font and zoom

***View ▸ Font & Zoom ▸ Font…*** picks the document font family and size.
`Ctrl+scroll`, `Ctrl++` and `Ctrl+-` zoom on the fly, and `Ctrl+0` resets. Your
choice persists and overrides whatever the active theme would have used.

This is the *document* font only — the menus and dialogs keep the system UI font,
so zooming in on code doesn't reflow the whole application.

## Column (block) editing

Off by default; turn it on in ***Settings ▸ Column Editing***. Then
**`Ctrl+Shift`+drag** a vertical cursor down through several lines. Typing,
Backspace, Delete and Tab all act at that column on **every** line at once, and
the whole thing is a single undo step. Drag a *width* as well as a height and
typing overwrites the rectangular block you selected.

This is the Notepad++ behaviour, and it is off by default because `Ctrl+Shift`+drag
is a normal selection gesture for people who don't use it.

## Comparing two documents

The **Compare** menu swaps the editor surface for a **side-by-side diff**:
original on the left, proposed on the right, added and removed lines coloured and
kept aligned.

- ***Compare With Another Tab…*** — against another open buffer, the common case.
- ***Compare With A File…*** — against any file on disk.
- `Esc` (or ***Close Compare***) returns you to editing.

The panes are read-only: compare is for *looking*, and rio would rather you edit
in the editor than in a diff. The [agent](agent.md) opens complex proposed edits
in this same view.

## Encoding and line endings

rio reads a file's text encoding and its line endings and writes back exactly what
it found — an LF file stays LF on Windows, a CRLF file stays CRLF on Linux, and a
UTF-8 file is not quietly re-encoded. Both are shown in the status bar, so what
will be written is never a surprise.

There is no "convert line endings" command yet. This is deliberate for now: silent
whole-file rewrites are the thing this behaviour exists to prevent, so the
conversion will arrive as an explicit action rather than as a side effect of
saving.

## When a file changes underneath you

Files move under an editor all the time — a `git pull`, a build, a discard from the
[git pane](git.md), another window. rio checks its open tabs when one of its own
writes lands and again when you switch back to the rio window, and then does the
least surprising thing:

- **You had no unsaved edits.** The tab reloads from disk, quietly. Nothing was
  yours to lose. It is a single undo step, so `Ctrl+Z` puts back what you were
  looking at.
- **You had unsaved edits.** rio asks before touching them, and the default answer
  is *no* — keep what you typed. Answer no and rio stops asking about that
  version; if the file changes again afterwards, it asks again.
- **The file was deleted.** rio asks whether to keep it open in the editor. Keep it
  and the tab stays, marked unsaved, because your copy is now the only one — saving
  it recreates the file. Decline and the tab closes.

rio does not watch the filesystem continuously, so a change made while you are
sitting in rio is noticed the next time rio writes something itself or you leave
and come back — not the instant it happens.

## Further reading

- [Keyboard shortcuts](keyboard.md) — the full default chord list, and remapping.
- [Editing modes](editing-modes.md) — vi and emacs keys inside the text area.
- [Find & replace](find-and-replace.md) — searching this buffer or the project.
- [Panels & layout](panels-and-layout.md) — themes, docking, and the tool panes.
