# ADR-0071: Relative line numbers

- **Status:** Accepted
- **Date:** 2026-09-05
- **Deciders:** jka
- **Decision log:** AGENTS.md D71

## Context

Users of motion counts, as in vi (`3j`, `5k`), read distances straight off a gutter
that shows each line's distance from the caret.

## Decision

The gutter (ADR-0049) has an optional relative mode, off by default, toggled from
View ▸ Relative Line Numbers or Preferences. It is a hybrid: the caret's line shows its
absolute number and every other line its unsigned distance from the caret.

It modifies the visible gutter rather than being a third gutter state. The gutter
width still follows the absolute last-line digit count, so toggling the mode or moving
the caret never changes the width. The gutter repaints on caret movement, coalesced to
idle, through the same path as the current-line highlight (ADR-0060). The label
calculation is a pure procedure, `gutter_label {ln caret relative}`, which tests cover
without a display.

## Consequences

- The feature composes with the gutter on/off setting and needs no layout changes.
- Painted numbers are not testable headless, as with the gutter itself.
