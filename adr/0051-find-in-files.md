# ADR-0051: Find in files: a core engine and a bottom results panel

- **Status:** Accepted; scope amended by [ADR-0052](0052-search-panel.md)
- **Date:** 2026-08-19
- **Deciders:** jka
- **Decision log:** AGENTS.md D51

## Context

ADR-0036 anticipated this: with a remote core, only the core can see the project
tree, so searching it has to run in the core. The results need a place in the UI.

## Decision

- **Engine:** `project.search {needle, ?nocase?, ?wholeword?}` walks the open project
  and returns matching lines grouped by file:
  `{count, files, truncated, results: [{path, rel, matches: [{line, col, cols, text}]}]}`.
  It skips `.git/`, binary files (containing a NUL byte) and oversized files, and caps
  result rows. `count` is total occurrences; the list shows one row per matching line.
  `cols` lists every occurrence's start column, so the frontend highlights hits
  without re-matching.
- **Whole word:** a hit counts only when neither neighbour is a letter, digit or
  underscore (Unicode letters included). The same boundary rule was added to the
  in-buffer operations, so the find bar and the panel agree.
- **Results panel:** a tool window docked at the bottom, in the manner of Visual
  Studio's Find Results. It has a query row and a rich list with a header row per file
  and one row per match; hits are tinted. Ctrl+Shift+F opens it, seeded from the
  selection; activating a row opens the file at that line. Search runs on Enter, not
  on each keystroke.

## Alternatives considered

The results could have been a tab in the side dock or a separate window. A bottom
panel keeps documents in the centre and matches the tool-window model of ADR-0035.

## Consequences

- This is the first two-level result in the protocol, with an explicit encoder
  (ADR-0025).
- Regular expressions, glob filters and replace across files were deferred and then
  added in ADR-0052.
