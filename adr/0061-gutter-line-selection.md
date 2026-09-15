# ADR-0061: Click a line number to select the line

- **Status:** Accepted
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D61

## Context

In most editors, clicking a line number selects the line and dragging extends the
selection line by line. The gutter of ADR-0049 was display-only.

## Decision

Pressing on a gutter number selects that whole logical line; dragging extends the
selection over the lines between the anchor and the pointer, in either direction.

Because the gutter paints each number at the text widget's own y position, a click's
y coordinate maps back to a logical line with `index @0,y`. The selection covers the
line including its newline and is clamped at the end of the buffer. The press moves
keyboard focus to the text widget, so the status bar and current-line band follow.

## Consequences

- The feature is a binding on the existing gutter; the core is untouched.
