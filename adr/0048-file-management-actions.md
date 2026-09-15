# ADR-0048: File management as core operations

- **Status:** Accepted; target directory rule amended by [ADR-0087](0087-files-tree.md)
- **Date:** 2026-08-18
- **Deciders:** jka
- **Decision log:** AGENTS.md D48

## Context

The files pane could browse and drive git but not create, rename or delete files.

## Decision

- **Core operations:** `fs.create {path, ?type file|dir?}`, `fs.rename {path, to}` and
  `fs.delete {path}`, resolved against the project root, reporting failures as
  `io_error`, and emitting `fs.changed` (two events for a rename). Create and rename
  refuse to overwrite an existing path. Delete is recursive.
- **Open buffers follow the file.** On rename, the GUI updates the path of every
  affected buffer, locally and in the core through `buffer.setpath`, so a later save
  writes to the new name. On delete, affected tabs are closed without a save prompt.
- **Input:** a small modal name prompt, which fits the Windows 2000 period and needs
  no theme wiring. Names must be a single path component.
- **Confirmation:** delete is confirmed with a dialog whose default is No.

## Consequences

- File management works over a remote core.
- Without `buffer.setpath`, a renamed tab's next save would recreate the old file;
  the core's view of a buffer's path must stay in step with the GUI's.
- Every irreversible action since then uses a confirmation that defaults to No.
- The rule for where New creates a file changed with the tree view (ADR-0087).
