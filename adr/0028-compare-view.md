# ADR-0028: A core line diff and a read-only compare view

- **Status:** Accepted
- **Date:** 2026-06-29
- **Deciders:** jka
- **Decision log:** AGENTS.md D28

## Context

The layout reserved space for side-by-side diffs (ADR-0013, ADR-0014), and the
agent's proposed edits needed a better review surface than an inline diff in a
narrow chat column.

## Decision

- **Core:** `diff.lines {a, b}` returns the operations that turn text A into text
  B, each `{tag equal|delete|insert, a, b}` with 1-based line numbers (0 where a
  side has no line). It is a classic LCS diff in `rio-core/diff.tcl`, splitting
  lines exactly like the document model.
- **GUI:** a compare view of two read-only panes with a shared scrollbar, shown in
  place of the editor while comparing. Filler rows keep equal lines level. Each line
  carries a `-` or `+` marker in addition to its colour, so the diff reads even where
  tag backgrounds render poorly.
- **Agent:** `agent.proposal {turn}` returns a pending proposal's full original and
  proposed text on demand; the `agent.propose` event stays small. A proposal larger
  than a threshold opens in the compare view automatically; smaller ones stay
  inline. A Compare button opens any proposal, and a setting disables the automatic
  opening.

## Consequences

- The diff computation is shared with any future frontend.
- The compare view is its own read-only surface rather than an editor group.
  Folding it into the editor groups of ADR-0033 is a possible later simplification.
- The unified-diff fallback for narrow displays is not built.
- The O(n·m) algorithm is fine for source files; large files are out of scope, as
  elsewhere.
