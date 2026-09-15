# ADR-0064: Menus are kept within screen height by grouping

- **Status:** Accepted
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D64

## Context

On X11, a Tk menu posted taller than the screen space below it unposts when the
pointer hovers an item part-way down. The View menu had grown to about 30 rows and
triggered this.

## Decision

Menus are kept short enough to fit, rather than fixing Tk's menu internals (see
ADR-0059). Less frequently used View items were grouped into cascades: Dock Side,
Font & Zoom, and Editor Layout. Frequently toggled display options and the pane
toggles stay at the top level. The View menu went from about 30 rows to about 18.

A test asserts that the View menu stays small and that the cascades exist.

## Consequences

- Standing rule: a rio menu stays within screen height by grouping.
- Data-driven menus with no upper bound are not acceptable. The Tabs menu
  (ADR-0074) and the Theme menu (ADR-0092) were later replaced with bounded dialogs
  for this reason.
- The underlying X11 behaviour is recorded in CAVEATS.md.
