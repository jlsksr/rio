# Keyboard shortcuts

rio's default chords, and the two ways to change any of them.

Every shortcut comes from one table, so remapping a key moves the key *and* the
label the menus show beside it.

## Changing a shortcut

**In rio.** ***Settings ▸ Keyboard Shortcuts…*** lists every command. The same
editor opens from *Preferences ▸ Keyboard ▸ Edit Keyboard Shortcuts…*.

1. Click a shortcut.
2. Press the keys you want. They are recorded as you press them.
3. Press **Save**.

*Clear* unbinds a command, *Default* restores one command's original chord, and
*Reset all to defaults* starts over. Save applies at once — no restart — and
writes the file below for you. A conflict, or a key that would be unusable (a
lone letter, a bare modifier), is refused with a note rather than accepted.

**By hand.** Edit `keys.json` in your config directory, by default
`~/.config/rio/keys.json`, beside `prefs.json`. It holds **overrides only**:
list the commands you want to change, and everything else keeps its default. No
file means all defaults. It is plain JSON, parsed and never executed, and a hand
edit takes effect at the next start.

```json
{
  "close-tab": "Control-k",
  "save-as":   "Control-Shift-s",
  "quit":      ""
}
```

A value is a chord in Tk's spelling: the modifiers `Control`, `Shift` and `Alt`
joined by `-`, then the key — a letter, or a key name such as `Tab`, `F3`,
`backslash`, `bracketright`. On a Mac the modifiers are `Command`, `Option`,
`Control` and `Shift`, so ⌘K is `Command-k` (`Alt` matches no key there). With
Option, name the character Option types rather than the letter: ⌥F types ƒ, so
⌥⌘F is `Option-Command-function`. Recording the chord in the shortcut editor spells
it for you. An empty string unbinds the command and leaves it on the menu only.

A capital letter implies Shift, so `Control-Shift-s` and `Control-S` are the
same binding. The menu shows either as `Ctrl+Shift+S`.

If an entry names an unknown command, or a chord with a misspelled modifier, rio
ignores just that line, applies the rest, and tells you once at startup. A bad
`keys.json` never stops the editor.

## The defaults

The left-hand column is the name to use in `keys.json`; the middle is what the
menus show.

| Command | Default | Does |
| ------- | ------- | ---- |
| `new` | `Ctrl+N` | New tab |
| `open` | `Ctrl+O` | Open file… |
| `open-folder` | `Ctrl+Shift+O` | Open folder as project… |
| `save` | `Ctrl+S` | Save |
| `save-as` | `Ctrl+Shift+S` | Save As… |
| `close-tab` | `Ctrl+W` | Close the current tab |
| `quit` | `Ctrl+Q` | Quit |
| `undo` | `Ctrl+Z` | Undo |
| `redo` | `Ctrl+Shift+Z` | Redo |
| `redo-alt` | `Ctrl+Y` | Redo (alternate) |
| `find` | `Ctrl+F` | Find… (the find bar) |
| `replace` | `Ctrl+H` | Replace… (the find bar's replace row) |
| `find-next` | `F3` | Find next |
| `find-prev` | `Shift+F3` | Find previous |
| `search` | `Ctrl+Shift+F` | Search… (the project-wide Search panel) |
| `next-tab` | `Ctrl+Tab` | Next tab |
| `prev-tab` | `Ctrl+Shift+Tab` | Previous tab |
| `show-files` | `Ctrl+Shift+E` | Toggle the files pane |
| `show-git` | `Ctrl+Shift+G` | Toggle the git pane |
| `toggle-wrap` | `Ctrl+Shift+W` | Toggle line wrap |
| `toggle-linenums` | `Ctrl+L` | Toggle the line-number gutter |
| `toggle-chat` | `Ctrl+Shift+A` | Toggle the agent pane |
| `split-editor` | `Ctrl+\` | Toggle the editor split |
| `move-tab-other` | `Ctrl+]` | Move the tab to the other editor group |
| `preferences` | *(unbound)* | Open the Preferences window |
| `help` | `F1` | Open this manual inside rio (***Help ▸ Contents…***) |

`preferences` ships with no chord. The command exists and sits on the *Settings*
menu; give it one like any other.

A pane's chord (`show-files`, `show-git`, `toggle-chat`) works with focus anywhere
in the window. A pane in front hides; one behind or hidden comes to the front.

## On a Mac

rio uses `Cmd` wherever the table above says `Ctrl`: `Cmd+S` saves, `Cmd+F`
finds, `Shift+Cmd+F` searches. `Ctrl` is left to macOS's own text keys, which
work in rio as in any Mac text field. The menus show the Mac's symbols (⌘S,
⇧⌘F), and the shortcut editor records `Cmd` and `Opt` as you press them.

Four commands keep a different chord, because macOS already uses the `Cmd` one:

| Command | On a Mac | Why |
| ------- | -------- | --- |
| `quit` | *(unbound)* | The application menu's *Quit rio*, `Cmd+Q`, already asks about unsaved work. |
| `replace` | `Opt+Cmd+F` | `Cmd+H` hides rio. `Opt+Cmd+F` is the Mac's own Replace. |
| `next-tab` | `Ctrl+Tab` | `Cmd+Tab` switches between applications. |
| `prev-tab` | `Ctrl+Shift+Tab` | The same. |

The application menu's *Preferences…* (`Cmd+,`) and *About rio* open rio's own
windows.

`find-next` and `find-prev` stay on `F3`. A Mac keyboard may need `fn` for that;
`Return` and `Shift+Return` in the find bar step through matches too.

## Keys this table does not cover

| Keys | Belong to |
| ---- | --------- |
| `Ctrl+A`, `Ctrl+C`, `Ctrl+X`, `Ctrl+V`, Home, End and the other text motions | The **editing mode** — Windows, vi or emacs. Each mode has its own idea of what they do. See [editing modes](editing-modes.md). On a Mac, the Windows mode's are `Cmd+A`, `Cmd+C`, `Cmd+X` and `Cmd+V`. |
| `Ctrl+scroll`, `Ctrl++`, `Ctrl+-`, `Ctrl+0` | Zoom, on the ***View ▸ Font & Zoom*** submenu. On a Mac, `Cmd` as well. |
| The `Menu` key, `Shift+F10` | Opening the editor's [right-click menu](editor.md#the-right-click-menu) at the caret. |
| `Esc` | Closing the find bar, and leaving the compare view. |

The *Edit* menu shows no accelerator beside Cut, Copy and Paste for the same
reason: the label would be wrong in vi mode. The menu commands work in every
mode.

**App shortcuts always win over the editing mode's keys.** `Ctrl+S` saves
whether or not you are in vi's insert mode, so a mode can never capture a key
you need to save or quit with.

## Further reading

- [Editing modes](editing-modes.md) — what the keys inside the text area do.
- [Preferences](preferences.md) — where `keys.json` sits among the other files.
