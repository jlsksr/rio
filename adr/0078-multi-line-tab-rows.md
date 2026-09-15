# ADR-0078: Multi-line tabs flow into packed, justified rows

- **Status:** Accepted
- **Date:** 2026-09-08
- **Deciders:** jka
- **Decision log:** AGENTS.md D78

## Context

Multi-line tab mode (ADR-0057) placed tabs with `grid`. Grid forces equal column
widths across rows, so short tabs left gaps, and the widened columns made rows wider
than the width calculation assumed, clipping the last tab of a row.

## Decision

Each visual row is a frame, and tabs are packed into it left to right with `pack -in`,
which respects each tab's natural width. A new row starts before a tab would overflow.
Rows are then justified like a paragraph: every row except the last expands its tabs
to fill the width; the last row keeps natural widths.

Because `pack -in` does not reparent, the row frames are siblings of the tabs and must
be lowered beneath them; otherwise their backgrounds cover the tabs. A test asserts
the stacking order.

## Consequences

- Rows are tight and fill the strip without clipping.
- Width calculation remains analytic, so layout is still synchronous and testable
  without a display.
