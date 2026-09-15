# ADR-0090: Undo coalescing by word, decided in the core

- **Status:** Accepted
- **Date:** 2026-09-10
- **Deciders:** jka
- **Decision log:** AGENTS.md D90

## Context

Every keystroke was its own undo step, so undoing a typed word took one undo per
letter. Grouping had been planned from the start. The questions were where the grouping
is decided and what the unit is.

## Decision

Grouping is decided in the core, in `rio::doc::edit`, the single path every edit takes.
The undo history belongs to the core (ADR-0003), so every frontend gets the behaviour
with no view change, and undoing a group emits one `buffer.changed`.

The rule is **word granularity**:

- A new edit merges into the top undo record if it is a single character that
  continues it: typing forwards at the end of the run, Backspace immediately before its
  start, or Delete repeated at the same position.
- A run ends after a blank character joins it, so "the " and "quick " are separate
  steps.
- A newline never joins a run.
- Anything else (a paste, typing over a selection, Replace All, an agent edit, any
  multi-character edit) is its own step and closes the run.

The core uses neither a clock nor the caret. A run continues only while edits are
adjacent, so moving the caret and typing elsewhere ends it without the frontend
reporting cursor moves (ADR-0022).

`buffer.replace` accepts an optional `coalesce` flag, default on. A frontend sends `0`
for a discrete command, meaning "start a new step here". The flag breaks the run before
the edit, and the new step can still grow. The vi extension sets it on every
normal-mode and visual-mode key, so repeated `x` or `dd` are separate undo steps while
`i` followed by typing is one.

## Alternatives considered

- **Whole-run grouping as in vim.** The maintainer chose word granularity.
- **An idle timeout that ends a run.** Rejected for now because it makes the model
  time-dependent; it could be added later without changing the protocol.

## Consequences

- Undo behaves as users expect, in every frontend.
- Two identical single-character deletions are indistinguishable to the core; only the
  frontend knows whether they were one gesture, hence the `coalesce` flag.
- A reload of a changed file is always its own undo step (ADR-0094).
