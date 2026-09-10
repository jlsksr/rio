# Editing modes

What the keys do *inside* the text area: Windows by default, or vi or emacs once
installed.

**This topic is still to be written.** It will cover: the shipped **Windows** mode
(Notepad/VSCode keys — `Ctrl+A` selects all, `Ctrl+V` pastes); **emacs/readline**
(`Ctrl+A`/`Ctrl+E` line motion, `Ctrl+K` kill, `Ctrl+V` scrolls); **vi** (modal
editing — motions, counts, the `d`/`c`/`y` operators, visual mode, a block cursor
in normal mode, and its own undo granularity); choosing one in *Settings ▸ Editing
Mode*; the mode indicator in the status bar; and writing or dropping in a mode of
your own.

For now, the *Editing modes* entry under **What works now** in
[README.md](../README.md) describes all three, and
[preferences](preferences.md#editing-modes-beyond-windows) explains how vi and
emacs are installed and where they live.

Two rules hold in every mode, and are worth knowing now:

- **App shortcuts always win.** `Ctrl+S` saves even in vi's insert mode.
- **The mode owns the clipboard keys**, which is why the *Edit* menu shows no
  accelerators beside Cut, Copy and Paste — the menu commands work regardless.

- [Keyboard shortcuts](keyboard.md) — the app chords, which are separate from this.
- [The editor](editor.md#undo-and-redo) — undo granularity, including vi's.
