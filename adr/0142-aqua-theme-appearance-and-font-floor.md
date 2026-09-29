# ADR-0142: On Aqua, the theme reaches the native controls, and chrome text has a floor

- **Status:** Accepted
- **Date:** 2026-09-29
- **Deciders:** jka
- **Decision log:** AGENTS.md D135

## Context

A screenshot run on macOS found two faults that no headless check had caught.

- On Aqua, Tk draws `button`, `menubutton` and `checkbutton` as native controls, which
  ignore `-background`. Dark themes (Solarized Dark, night) showed light buttons.
- Tk converts font points with `tk scaling`: 1.33 px/pt on X11, 1.0 on Aqua. The theme's
  UI size 9 was 12px on Linux and 9px on a Mac, below macOS's own interface text.

ADR-0024 (D24) puts every Tk-specific mapping of a theme in the GUI applier.

## Decision

**The native appearance follows the theme's lightness.** On Aqua, `apply_theme` sets
`::tk::unsupported::MacWindowStyle appearance` to `darkaqua` when `ui.bg` is dark, else
`aqua`, on every toplevel. A `Toplevel` `<Configure>` binding catches new ones once their
native window exists. Every call is inside `catch`.

**Chrome and chat text have an 11pt floor on Aqua.** `ensure_fonts` raises every named font
except `RioEditorFont`, and every fixed-width chrome literal goes through `chrome_font`,
which applies the same floor. The editor keeps the theme's size and the user's override.

## Alternatives considered

- **`appearance auto`.** Rejected. It follows the system setting, not rio's theme.
- **Replacing buttons with styled labels.** Rejected. A second button implementation just
  for Aqua, without keyboard or default-button behaviour.
- **`ttk::style theme use clam`.** Rejected. It gives rio an un-Mac look on a Mac.
- **`tk scaling 96/72` on Aqua.** Rejected. It also grows the editor to 16px and every
  dimension given in points.

## Consequences

- Buttons, menubuttons and checkboxes draw dark in a dark theme and light in a light one.
- Native menus and system dialogs still follow the system setting.
- Chrome text on a Mac is 11px instead of 9px. X11 and Windows are unchanged.
- The theme data does not change.
- Headless checks cover both. Nobody has looked at the result on a screen yet.
