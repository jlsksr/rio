# Keyboard shortcuts

rio's default chords, and the two ways to change any of them.

Every editor shortcut is **data**, defined in one table — so a remap moves the key
*and* the accelerator label shown in the menus together, and they cannot drift
apart.

## Changing them

- **In the editor** — ***Settings ▸ Keyboard Shortcuts…*** lists every command.
  Click a shortcut and press the keys you want (press-to-capture, like a modern
  IDE); *Clear* unbinds one, *Default* restores a single command's original chord,
  and *Reset all to defaults* starts over. **Save** applies immediately — no
  restart — and writes the file below for you. Conflicts and unusable keys (a lone
  letter, a bare modifier) are refused with a note rather than accepted and broken.
- **By hand** — edit `keys.json` in your config directory (default
  `~/.config/rio/keys.json`), a sibling of `prefs.json`. It is **overrides only**:
  list just the commands you want to change, and everything else keeps its default.
  Optional (no file means all defaults), plain JSON, parsed and never executed. A
  hand-edit takes effect at the next launch.

```json
{
  "close-tab": "Control-k",
  "save-as":   "Control-Shift-s",
  "quit":      ""
}
```

A value is a **chord** in Tk syntax: the modifiers `Control`, `Shift` and `Alt`
joined by `-`, then the key — a letter, or a key name like `Tab`, `F3`,
`backslash`, `bracketright`. An empty string `""` unbinds the command, leaving it
menu-only.

A capital letter implies Shift the way Tk reads it, so `Control-Shift-s` and
`Control-S` are the same binding; the menu shows either as `Ctrl+Shift+S`.

If an entry names an unknown command, or a chord with a misspelled modifier, rio
ignores **just that line** — the rest still apply — and tells you once at startup.
A bad `keys.json` never stops the editor.

## The defaults

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
| `find` | `Ctrl+F` | Find… (the in-buffer find bar) |
| `replace` | `Ctrl+H` | Replace… (the find bar's replace row) |
| `find-next` | `F3` | Find next |
| `find-prev` | `Shift+F3` | Find previous |
| `search` | `Ctrl+Shift+F` | Search… (the project-wide Search panel) |
| `next-tab` | `Ctrl+Tab` | Next tab |
| `prev-tab` | `Ctrl+Shift+Tab` | Previous tab |
| `show-files` | `Ctrl+Shift+E` | Show the files pane |
| `show-git` | `Ctrl+Shift+G` | Show the git pane |
| `toggle-wrap` | `Ctrl+Shift+W` | Toggle line wrap |
| `toggle-linenums` | `Ctrl+L` | Toggle the line-number gutter |
| `toggle-chat` | `Ctrl+Shift+A` | Toggle the agent pane |
| `split-editor` | `Ctrl+\` | Toggle the editor split |
| `move-tab-other` | `Ctrl+]` | Move the tab to the other editor group |
| `preferences` | *(unbound)* | Open the Preferences window |

`preferences` ships with no chord — the command exists and sits on the *Settings*
menu, and you can give it one like any other.

Left-hand column entries are the names to use in `keys.json`; the middle column is
what the menus show.

## Keys the table doesn't cover

Three groups of keys work without appearing above, because they don't belong to
this table:

- **The clipboard and text motion** — `Ctrl+A`, `Ctrl+C`, `Ctrl+X`, `Ctrl+V`,
  Home/End, and so on. These belong to the **editing mode** (Windows, vi or emacs),
  because each mode has its own idea of what they should do. See
  [editing modes](editing-modes.md). The *Edit* menu deliberately shows no
  accelerators for Cut/Copy/Paste for the same reason — a fixed label there would
  be a lie in vi mode. The menu commands themselves work in every mode.
- **Zoom** — `Ctrl+scroll`, `Ctrl++`, `Ctrl+-`, `Ctrl+0`, on the *View ▸ Font &
  Zoom* submenu.
- **`Esc`** — closes the find bar and leaves the compare view.

**App shortcuts always win over the editing mode's keys.** `Ctrl+S` saves whether
or not you are in vi's insert mode, so a mode can never capture a key you need to
save or quit with.

## Further reading

- [Editing modes](editing-modes.md) — what the keys inside the text area do.
- [Preferences](preferences.md) — where `keys.json` sits among the other files.
- [AGENTS.md](../AGENTS.md) — the reasoning behind one table for keys and menu
  labels alike, if you want it.
