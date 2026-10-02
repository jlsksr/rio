# ADR-0146: Undo has a budget, and a step holds a text once

- **Status:** Accepted
- **Date:** 2026-10-02
- **Deciders:** jka

## Context

Undo history lives in the core, per buffer ([ADR-0003](0003-core-owns-the-document.md)),
coalesced by word ([ADR-0090](0090-undo-coalescing.md)). It grew without limit:

- **A step was a dict** `{start end text removed}`: 985 bytes for a typed word, measured.
- **A whole-text step held the file twice.** A reload ([ADR-0094](0094-stale-buffers.md))
  or a Replace All kept the old text and the new, and the new one is also the document.
- **Nothing was ever dropped.** A day in one buffer, or a few Replace Alls in a big file,
  stayed in RAM until the tab closed.

rio must run on a Raspberry Pi.

## Decision

- **A step is a list** `{start end iend held}`. `iend` is where the inserted text ends.
  279 bytes for a typed word.
- **`held` is the half the document does not have.** Undo swaps it with the document's
  half and moves the step to the redo stack; redo swaps back.

```
              the document has     the step holds
 undo stack   the inserted text    the removed text
 redo stack   the removed text     the inserted text
```

- **Each stack of each buffer has a budget:** 4,194,304, counted as held characters plus
  300 a step. Over it, the oldest steps go.
- **The newest step always stays.** A reload of a file bigger than the budget can still
  be taken back.
- **The budget is a constant** in `rio-core/document.tcl`, not a preference.

## Alternatives considered

- **Cap the step count.** Ten typed words and ten Replace Alls in a 10 MB file are not
  the same cost.
- **A preference.** Nobody can pick the number; a wrong one loses work or RAM.
- **One budget across all buffers.** Editing one file would eat another's history.
- **Spill old steps to disk.** A second store to keep correct, for steps no one reaches.

## Consequences

- At least 13,000 typed words can be undone in one buffer; a reload costs one copy of
  the file, not two.
- Worst case per buffer is two budgets, or the one newest step if that is larger.
- Old steps vanish silently. Undo simply stops earlier.
- The count is in characters; Tcl may store two bytes for one.
- The redo stack, over budget, loses the edits furthest from the present state.
