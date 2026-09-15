# ADR-0047: Disk writes are announced with `fs.changed`

- **Status:** Accepted
- **Date:** 2026-08-18
- **Deciders:** jka
- **Decision log:** AGENTS.md D47

## Context

A file created by the agent did not appear in the files pane until the user
refreshed by hand. The core broadcast `buffer.changed` for edits to open buffers, but
nothing for writes straight to disk.

## Decision

- **An event.** Operations that write to disk outside a buffer emit
  `fs.changed {path}` with an absolute path. The agent forwards it when it creates a
  file or edits a closed one. `file.save` does not emit it, because the saving GUI
  already refreshes locally. The GUI repaints the git pane on any change and the
  files pane when the change is in a directory it is showing.
- **A manual refresh.** The files pane header gets a `⟳` refresh button, like the git
  pane, for changes rio did not make.
- **Refresh on focus return.** When the application regains operating-system focus,
  the shown pane refreshes once. This is detected from focus events on the top-level
  window, debounced, and only on a real change from "another application has focus"
  to "rio has focus". It is not polling.

## Consequences

- Writes rio makes appear in every connected frontend without user action.
- Changes made outside rio (another editor, `git pull`, a build) appear when the user
  returns to rio or presses refresh.
- rio still has no file watcher; a watcher in the core that emits `fs.changed` is the
  deferred complete answer, with its dependency and per-platform cost.
- ADR-0094 extended the same triggers to open buffers.
