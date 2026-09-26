# Editing modes

What the keys do *inside* the text area: Windows by default, or vi or emacs once
installed.

Pick one in ***Settings ▸ Editing Mode***.

| Mode | Keys |
| ---- | ---- |
| Windows | Notepad and VS Code keys: `Ctrl+A` selects all, `Ctrl+V` pastes. Ships with rio. |
| emacs | readline motions: `Ctrl+A` and `Ctrl+E` for start and end of line, `Ctrl+K` kills, `Ctrl+V` scrolls. An [extension](extensions.md). |
| vi | Modal editing: motions, counts, the `d`, `c` and `y` operators, visual mode, a block cursor in normal mode, and vi's own undo granularity. An [extension](extensions.md). |

**This topic is still to be written.** It will cover each mode's keys in full,
the mode indicator in the status bar, and writing or dropping in a mode of your
own.

Until then, the *Editing modes* entry in [README.md](../README.md) summarises
all three, and [preferences](preferences.md#editing-modes-beyond-windows)
explains how vi and emacs are installed and where they live.

## Two rules that hold in every mode

- **App shortcuts always win.** `Ctrl+S` saves even in vi's insert mode.
- **The mode owns the clipboard keys**, which is why the *Edit* menu shows no
  accelerators beside Cut, Copy and Paste. The menu commands work regardless.

## Further reading

- [Keyboard shortcuts](keyboard.md) — the app chords, which are separate from
  the mode's keys.
- [The editor](editor.md#undo-and-redo) — undo granularity, vi's included.
