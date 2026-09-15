# ADR-0087: The files pane becomes a tree from the project root

- **Status:** Accepted
- **Date:** 2026-09-09
- **Deciders:** jka
- **Decision log:** AGENTS.md D87

## Context

The files pane showed one directory at a time: a `..` row went up, and opening a folder
replaced the view. Only one level was ever visible. Users wanted to unfold directories
in place, as in VS Code and Windows Explorer.

## Decision

The pane is a tree rooted at the open project root.

- Directories have a `▸` or `▾` marker. A **single click on the marker** (or the
  indentation to its left) folds or unfolds the directory. A **double click on the
  name** toggles a directory or opens a file; Return does the same. A single click on
  the name selects.
- The `..` row and replace-the-view navigation are removed.
- Folding keeps the unfolded state of descendants, so reopening a directory restores
  its previous shape.
- The set of unfolded directories is held in `::nav_expanded`; `::nav_root` is always
  the project root.
- Rows are rendered recursively from `fs.list`, one level per call. The two-character
  git status column stays aligned at every depth, and directory roll-up still marks a
  folded folder containing changes.
- Automatic refresh (ADR-0047) repaints when a change lands in any directory currently
  on screen.
- File management (ADR-0048) targets the clicked row: New creates inside a directory
  row (unfolding it) or beside a file row; Rename and Delete apply to any row.

The click routing (marker versus name) is a pure function of row type, depth and
column, tested without a display.

## Consequences

- The whole project structure is navigable in place, with the same list component.
- Persisting the unfolded shape was deferred and then added in ADR-0089.
- Drag and drop between folders is out of scope.
