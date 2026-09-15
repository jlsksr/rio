# ADR-0024: Themes are semantic-role data files

- **Status:** Accepted
- **Date:** 2026-06-25
- **Deciders:** jka
- **Decision log:** AGENTS.md D24

## Context

The GUI should be themeable, with live switching and different typography for the
code surface and the chat. Themes that name widget paths break whenever the widget
tree changes, and themes written as Tcl scripts would execute code.

## Decision

A theme is a data file in the configuration format of ADR-0021, parsed and never
executed. It names **semantic roles**, not widgets:

- **Colours by role**, for example `editor.bg`, `editor.fg`, `editor.selection`,
  `ui.bg`, `tab.active.bg`, `gutter.fg`, `chat.bg`, `accent`. Two themes differ only
  in values.
- **Fonts by role**, through Tk named fonts (`RioEditorFont`, `RioUIFont`,
  `RioChatFont`). Reconfiguring a named font updates every widget that uses it,
  so size and theme changes need no restart.

A theme may declare `base = <theme>` and override a subset of roles. The core
serves the merged role table (`theme.get`); a small applier in the GUI maps it
onto Tk. The default theme is the plain white background and black text. Later
decisions added roles rather than hard-coded colours: `error`, the diff roles,
`syntax.*` (ADR-0032), `editor.findmatch` (ADR-0036) and `editor.currentline`
(ADR-0060). A theme that omits a role inherits the default.

## Consequences

- A new theme is a set of values, and theme files cannot break or compromise rio.
- The colour-role vocabulary is shared, so a future TUI can map the same roles onto
  a terminal palette.
- The Tk-specific mapping lives in one applier in the GUI.
- Tooltips are the one deliberate exception and ignore the theme (ADR-0063).
