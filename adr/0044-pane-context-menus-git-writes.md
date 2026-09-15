# ADR-0044: Pane context menus and the first git write operations

- **Status:** Accepted
- **Date:** 2026-08-07
- **Deciders:** jka
- **Decision log:** AGENTS.md D44

## Context

The panes could show git state but not act on it; tracking an untracked file meant
switching to a terminal. Git had been read-only since ADR-0007.

## Decision

- Both rich-list panes get **right-click context menus**, built fresh for each popup
  and scoped to the row that was clicked. Right-clicking selects the row without
  triggering its primary action.
- The files menu offers Open and Copy Path, plus git actions that depend on the
  row's status: Track (git add) for an untracked file, Stage for a modified one,
  Unstage for a staged one, Stage folder for a directory with changes. The git menu
  offers Open, Copy Path, and Stage or Unstage.
- The core gains `git.add` (`git add -- <path>`) and `git.unstage`
  (`git reset -q -- <path>`). `reset` is used rather than `restore --staged` because
  it also works in a repository with no commits yet.

Commit and discard were left for separate decisions (ADR-0045, ADR-0080).

## Consequences

- Git write operations run in the core, so the menus work over a remote core.
- Every later context menu follows the same rule: a menu holds actions about its
  target and nothing about other elements.
- Menu construction is split from the popup call so tests can read entry labels
  without a display.
