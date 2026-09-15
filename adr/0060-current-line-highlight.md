# ADR-0060: Current-line highlight

- **Status:** Accepted
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D60

## Context

Most editors tint the line holding the caret, which helps locate the caret at a
glance.

## Decision

The editor tints the logical line containing the caret with a faint full-width band.
It is on by default and can be turned off from View ▸ Highlight Current Line or the
Preferences window, which share one variable and applier (ADR-0058).

- It is a display tag (`curline`) spanning the line including its newline, so the band
  covers the full width and every display row of a wrapped line.
- It is per editor group and recomputed wherever the caret can move.
- Its colour is the theme role `editor.currentline`; a theme without the role gets a
  faint blend of the editor background towards the foreground.
- The tag has the lowest priority, so syntax colours, selection, find matches and
  column bands draw over it.

## Consequences

- Nothing is added to the buffer; the feature is presentation only.
- Themes control the band like any other role.
