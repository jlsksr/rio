# ADR-0033: Two side-by-side editor groups

- **Status:** Accepted
- **Date:** 2026-07-06
- **Deciders:** jka
- **Decision log:** AGENTS.md D33

## Context

Users wanted two ordinary editable tabs next to each other, not the read-only
compare overlay of ADR-0028. The GUI was written around a single editor: one text
widget, one active buffer, one highlight cache, each a global.

## Decision

The split is a frontend feature; the core does not change. The core already holds
any number of buffers by id and has no opinion on how many are displayed
(ADR-0022).

- The single-editor globals are replaced by an **editor group** record (widget,
  tab order, active buffer, highlight cache). The GUI holds at most two groups and a
  focused group. Editor procedures take a group and default to the focused one.
  Existing behaviour was preserved first with one group, then the second group was
  enabled.
- Each group has **its own tab strip**, so a tab's group is where it is shown. A
  buffer belongs to exactly one group at a time.
- Actions: Split Editor, Move to Other Group, Unsplit. A group that becomes empty
  collapses into the other. A tab's context menu holds only actions about that tab
  (move, copy path, close); "Close Other Tabs" was rejected because it acts on
  other tabs.
- Tabs can be dragged between groups and reordered within a group with plain Tk
  press, motion and release bindings; no drag-and-drop extension is used. The first
  split centres the sash; later moves never override a width the user set.

The first version supports exactly two groups and does not persist the split
across restarts.

## Consequences

- A long-reserved capability landed with the core untouched.
- The single-editor assumption became a small explicit abstraction, which later
  features (find bar, modes, gutter, context menu) act on through the focused group.
- Showing the same buffer in both groups is deferred; it needs per-group view state.
- Merging the compare view into editor groups remains a possible later
  simplification.
