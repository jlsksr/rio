# ADR-0143: On a Mac, rio uses the Mac's keys and its right mouse button

- **Status:** Accepted
- **Date:** 2026-09-29
- **Deciders:** jka
- **Decision:** D136

## Context

rio's first macOS run (ADR-0140 to ADR-0142) fixed what a headless suite and a set of
screenshots can see. A review afterwards asked what a Mac user meets first that neither can
show, and found two things, both about input.

- **Right-click opened nothing.** In Tk 8.6 on Aqua the right mouse button is Button-2.
  Every context menu in rio (ADR-0108, ADR-0121, the file and git rows, the tabs) was bound
  to Button-3.
- **Every shortcut was a Control chord, on every platform.** On a Mac, Command is where
  applications put their shortcuts. Control belongs to the system's own text keys: Ctrl+A
  and Ctrl+E for the line start and end, Ctrl+K to kill, and a few more. They work in every
  Mac text field, and Tk's Text class already implements them.

Two facts about Tk on Aqua shape the answer:
- **A menu accelerator only flashes the menu there.** The binding does the work, so a
  Command binding with a matching menu label does not fire twice. The application menu's
  own items (Quit, Hide, Preferences) are Cocoa's rather than Tk's, and those *do* act on
  their Command chords.
- **The modifier bits differ.** Command is `Mod1` (state `0x8`) and Option is `Mod2`
  (`0x10`). Tk's `Alt` matches no key at all.

## Decision

**rio's right-click menus bind `<<ContextMenu>>`.** It is Tk's own, platform-defined name
for the right button: Button-3 on X11 and Windows, Button-2 on Aqua.

**On a Mac the keymap reads Control as Command, with a short exception table.** The keymap
(ADR-0023) is kept as written, and the defaults in force are derived from it for the
running windowing system. On Aqua, every Control chord becomes the Command chord, except:

| Command | Chord on a Mac | Why |
| ------- | -------------- | --- |
| `quit` | unbound | the application menu's Quit (⌘Q) already reaches rio's quit |
| `replace` | ⌥⌘F | ⌘H is Hide |
| `next-tab` | ⌃Tab | ⌘Tab is the system's application switcher |
| `prev-tab` | ⌃⇧Tab | the same |

**The rest of the input surface follows the same rule:**
- Accelerator labels are drawn in the Mac's order and words.
- The shortcut recorder reads the Mac's modifier bits.
- Zoom (ADR-0056), the commit bar's ⌘Enter and the help window's ⌘F take Command as well.
- The application menu's Preferences… and About open rio's own windows.

**The Windows editing mode (ADR-0038) speaks the Mac's keys on a Mac.** It uses Cmd+A/C/X/V
and Opt+Backspace/Delete, and takes no Control key at all, so the system's text keys work.

## Alternatives considered

- **A second, hand-written Mac keymap.** Rejected. It would drift from the first the day a
  command was added to one only. One rule and four named exceptions cannot drift that way.
- **Keeping Control on a Mac.** Rejected. Every Mac habit points at Command, and Control
  there is already taken by the system's text keys.
- **Ctrl-click as right-click.** Rejected for now. The Windows mode's column gesture
  (ADR-0040) is Ctrl+Shift+drag, and a Control-click binding would take that press too.
- **⌘G and ⇧⌘G for find next and previous.** Not taken. `show-git` becomes ⇧⌘G under the
  rule, so it would need a second exception and a moved command. F3 still works, and so
  do Return and Shift+Return in the find bar.

## Consequences

- On a Mac, right-click and a two-finger click open rio's menus, but Ctrl-click does not.
- On a Mac, shortcuts are ⌘-based and the menus show ⌘ glyphs. A `keys.json` written there
  uses `Command` and `Option`, and a `keys.json` is no longer portable between a Mac and
  another platform.
- On a Mac, the Windows mode leaves Control alone, so readline-style keys work in it there
  but not on Linux or Windows.
- Nothing changes on X11 or Windows.
- The platform-dependent parts are pure functions of the windowing system, so the Mac's
  tables are checked on every host.
- What cannot be checked off a Mac is still owed to a Mac run: the glyphs as drawn, the
  two-finger click, and ⌘S saving exactly once.
- *(Amended 2026-09-29, first Mac run.)* Mac Tk looks a key up through the Option layer,
  so ⌥⌘F arrives as keysym `function` (ƒ). Replace is bound as `Option-Command-function`
  and still labelled ⌥⌘F; a check on Aqua sends the key through Tk's real lookup. See
  AGENTS.md D136.
