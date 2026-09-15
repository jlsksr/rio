# ADR-0050: Cursor position in the status bar

- **Status:** Accepted
- **Date:** 2026-08-19
- **Deciders:** jka
- **Decision log:** AGENTS.md D50

## Context

Users need to see the caret's line and column, compactly.

## Decision

The status bar shows `Ln L, Col C` for the focused group's caret, between the
language and buffer-count segments, as part of the existing single status label. The
column is shown 1-based, as in most editors, while Tk indexes from 0.

The segment updates on key release and mouse button release in each editor group,
and only when that group has focus. Edits already refresh the status bar. The
calculation is guarded so that an early or transitional call yields an empty segment
rather than an error.

## Consequences

- Pure navigation updates the display without touching the buffer.
- The selection size ("N selected") is deliberately not shown.
