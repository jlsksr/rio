# ADR-0012: Document model: a list of lines, `line.col` positions

- **Status:** Accepted
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D12

## Context

The core owns the document (ADR-0003), so it needs a representation and a
coordinate system for positions and edits. Candidates range from a plain list of
lines to gap buffers and ropes.

## Decision

A buffer is an ordered list of line strings. Positions and ranges use `line.col`
with a 1-based line and a 0-based column, which is the index format of Tk's
`text` widget. An edit is a range replacement: replace `[start, end)` with text.
Insertion and deletion are special cases. Change events carry the replaced range
and the new text so other views can resynchronise.

## Alternatives considered

A gap buffer or rope would scale better to very large files. For source-file
sizes a list of lines is simple, readable and fast enough; the alternatives were
judged premature.

## Consequences

- The GUI maps core positions onto the Tk widget without conversion, keeping the
  view layer thin.
- The `line.col` index also suits a character-cell terminal.
- `line.col` strings must never pass through `expr`: `1.10` becomes the number
  `1.1`. This defect appeared three times (the edit proxy, the find bar and the
  `buffer.find` handler) and is now a documented rule and a regression test.
- Large-file handling (lazy loading) remains an open question.
