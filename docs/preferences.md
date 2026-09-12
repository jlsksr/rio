# Preferences

Every setting rio keeps, what it does, and exactly which file on disk holds it.

Most settings are reachable from ***Settings ▸ Preferences…***, which gathers them
in one window; the ones you flip often also sit on the **View** and **Settings**
menus, as a second door to the same switch.

## Two kinds of saved state

rio persists two kinds of state, split by who owns it:

- **Preferences** — theme, line wrap, wrapped-line indent, line numbers, dock
  side, which panes are shown, the editor font. These are **global** and belong to
  the window, in `prefs.json` on the machine running the GUI. They load at **every**
  startup, with or without a project, so a bare `wish rio-gui/rio-gui.tcl file.txt`
  opens with your saved wrap, theme, and layout.
- **Workspace** — the files you had open in a project and which tab was active.
  This is **per-project** and belongs to the core, kept out of your source tree,
  keyed by project root. It resumes only when a **project** is open (you launched at
  a folder, or opened one); a bare file has no project, so nothing per-project comes
  back.

Neither ever holds your API key — that lives on its own, described below.

## Setting a default is just setting the value

**The last value *is* the default**, saved the moment you change it. There is no
separate "make this the default" step and no "save settings" button.

- **From the UI** — the **View** menu (Wrap Lines, Indent Wrapped Lines, Line
  Numbers, Theme…, Dock Left/Right, the pane toggles), the **Settings** menu
  (Column Editing, Editing Mode, the two agent toggles), and the shortcuts
  (`Ctrl+Shift+W` wrap, `Ctrl+Shift+A` agent pane, `Ctrl+L` line numbers). Each
  toggle rewrites `prefs.json` at once and is restored next launch.
- **By hand** — edit `prefs.json` directly. It is plain JSON, **parsed and never
  executed**:

  ```json
  {"theme":"solarized-dark","wrap":"1","wrap_indent":"1","line_numbers":"1","column_edit":"0","editmode":"windows","layout":{ }}
  ```

  | Key | Means |
  | --- | ----- |
  | `wrap` | `"1"` word-wrap on, `"0"` off |
  | `wrap_indent` | `"1"` aligns a wrapped line's continuation rows under its own indentation (visible only while `wrap` is on), `"0"` leaves them at the left margin |
  | `line_numbers` | `"1"`/`"0"` shows or hides the gutter |
  | `relative_line_numbers` | `"1"` numbers the gutter *relative to the caret* (vi-style), `"0"` counts from the top of the file |
  | `highlight_current_line` | `"1"` tints the line the caret sits on, `"0"` leaves it plain |
  | `column_edit` | `"1"` enables Notepad++-style column editing, `"0"` off |
  | `show_hidden` | `"1"` lists dot-files in the Files pane, `"0"` hides them (like `ls`) |
  | `tab_layout` | `scroll` — one row of tabs with ◂ ▸ arrows — or `multi`, wrapping them onto as many rows as they need |
  | `theme` | a name from `themes/`, or `default` |
  | `font_family` | an editor font overriding the theme's; empty means "use the theme's" |
  | `font_size` | the editor font size in points, 5–72; out-of-range values are ignored |
  | `editmode` | `windows`, `vi` or `emacs` — the last two only take effect once installed as extensions |
  | `project` | the folder that was open at the last launch, reopened on the next one (local cores only) |
  | `check_updates` | `"1"` looks for newer versions of your installed extensions shortly after start-up, `"0"` (the default) never touches the network unasked |
  | `layout` | a **nested object** holding the whole dock arrangement: which panes sit left, right or bottom, which are hidden, and their sizes |

  `layout` is fiddly to write by hand, so toggle it from the **View** menu and let
  rio record it. The file appears once you first change a setting (or quit), and
  you may create it by hand before the first run. Unknown or malformed keys are
  ignored, and a corrupt file is skipped rather than fatal.

> **Note.** There is not yet a *separate* hand-authored settings file distinct from
> this machine-written one: `prefs.json` is both your defaults and rio's saved
> state, so flipping a setting for one session changes your global default. For a
> simple global toggle like wrap, that is usually exactly what you want.

## Editing modes beyond Windows

The core ships the **Windows** editing mode only. **emacs** and **vi** install as
[extensions](extensions.md): add a repository that carries them under *Settings ▸
Extensions… ▸ Repositories…* and install from *Settings ▸ Extensions…*, or drop the
module by hand into `~/.config/rio/modes/` — a `mode` extension installs there, so
a hand-dropped file is exactly the same thing.

Once installed, the mode appears in *Settings ▸ Editing Mode*. If a saved
`editmode` names a mode that is no longer installed, rio falls back to Windows
rather than failing.

## Your repository list, by hand

The URLs you add under *Settings ▸ Extensions… ▸ Repositories…* are just an
apt-style sources file you can edit yourself: `sources.list`, **one `http://` base
URL per line**, with `#` comments and blank lines allowed. The dialog reads and
writes this exact format, so hand-edits and the GUI stay in step; a hand-edit is
picked up the next time the Extensions window scans.

On a **first run** rio pre-fills this file with the project's own repository
(`http://rio.skylm.org/rio`) so the Extensions window isn't empty out of the box.
Remove it in *Repositories…* (or delete the line) and it stays gone — the pre-fill
happens only when the file doesn't yet exist, never on top of your edits.
Otherwise it's optional: no file means no repositories.

What you have actually installed, and from where, is tracked separately in a
provenance ledger, `extensions.json` — rio writes it, and each entry records the
source URL and version a `kind/name` came from.

## Checking for extension updates

Extension versions follow [semver](https://semver.org/), so rio can tell you when
a repository offers something newer than what you have. It compares on every scan
— opening *Settings ▸ Extensions…* rescans, as does its `⟳` button — and shows the
answer on the row: `[1.1.0 → 1.2.0]`. **Update** replaces one extension;
**Update All** takes every pending update after a single confirmation listing them.
Nothing is ever installed on its own.

An update only comes from **the repository that extension was installed from**.
Nobody owns a name — there is no central index — so a same-named extension on
another host is treated as a different thing you may *switch* to by hand, not as a
newer version of yours. Where you know better, tick *Also accept updates from other
repositories* on that extension in the Extensions window.

*Preferences ▸ Extensions ▸ Check for extension updates at start-up* (the
`check_updates` key) makes rio look once, shortly after it starts, and tell you
what it found. It is **off** by default. A version that doesn't follow semver —
a date stamp, say — is shown but never compared, and never claimed to be out of
date.

## Where everything lives

There is **no single `~/.riorc`**: rio follows the XDG base-directory layout and
keeps one file per concern. Two roots, split by owner — **config** (your settings,
safe to hand-edit and to keep in version control) and **data** (rio's own
bookkeeping, machine-written, not meant for hand-editing).

**Config — `$XDG_CONFIG_HOME/rio/` (default `~/.config/rio/`):**

| Path | Holds | Edit by hand? |
| ---- | ----- | ------------- |
| `prefs.json` | GUI preferences — every key is listed [above](#setting-a-default-is-just-setting-the-value) | yes — plain JSON (above); `layout` best left to the View menu |
| `keys.json` | keyboard-shortcut **overrides** (defaults for everything you don't list) | yes — see [keyboard shortcuts](keyboard.md) |
| `sources.list` | extension-repository URLs, one `http://` base per line | yes (above) |
| `themes/` | user theme files, read by the **core** | drop-in / installed |
| `syntax/` | installed syntax highlighters (`*.tcl`) | drop-in / installed |
| `modes/` | installed editing modes — vi, emacs (`*.tcl`) | drop-in / installed |
| `agent/prompt.md` | replaces the shipped agent **base** prompt (rio's tool contract) — an override, not a layer | only if you mean it |
| `agent/plan.md` | replaces the shipped **plan-mode** prompt (how the agent investigates and what a plan should say) — an override, not a layer | only if you mean it |
| `agent/system.md` | your **system prompt**: standing instructions added on top, for every project and provider | yes — plain Markdown |
| `agent/providers/<name>.md` | a **per-provider prompt**, applied only while that provider is live | yes — plain Markdown |
| `agent/allow.list` | trusted commands for **all projects** — one rule per line | yes — plain text |
| `agent/providers/<name>.allow.list` | trusted commands active only while that provider is live | yes — plain text |

**Data — `$XDG_DATA_HOME/rio/` (default `~/.local/share/rio/`), rio-written:**

| Path | Holds |
| ---- | ----- |
| `sessions/` | per-project open files + active tab, keyed by project root |
| `providers/` | installed agent providers — the extension kind that ships executable code, so it lives with the data, not the hand-edited config |
| `extensions.json` | the provenance ledger — what's installed, from which repository, at which version |
| `secrets/*.secret` | API keys, mode `0600` — never in `prefs.json` |

**Project-local (in a project's own tree):**

| Path | Holds |
| ---- | ----- |
| `.rio/agent.md` | the **project prompt** — project-specific agent guidance, layered on top of the system prompt |
| `.rio/allow.list` | trusted commands for **this project only** |

Every one of these is optional: absent means "use the built-in default". Config
files are plain text (JSON, Markdown, or a one-rule-per-line list) — **data, parsed
and never executed** — and a malformed one is skipped with a note, never fatal.

The four `agent/` prompt files and the three allow-lists have friendly front doors
in *Preferences ▸ Agent* (*Agent Prompts…* and *Allowed commands…*); editing them
by hand and through the dialog are the same thing. The first two — the overrides —
exist only if you ask for them: *Agent Prompts… ▸ **Make my own copy…*** writes rio's
own shipped text here as your file, and rio then reads yours instead. Delete it and
rio's version comes back; you can read rio's version in that dialog either way. See
[the agent](agent.md).

## Further reading

- [Keyboard shortcuts](keyboard.md) — remapping, and `keys.json`.
- [Panels & layout](panels-and-layout.md) — what the `layout` object records.
- [INSTALL.md](../INSTALL.md) — installing and deploying rio, including where the
  agent's key and HTTPS support come from.
