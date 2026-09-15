# ADR-0089: Remember the unfolded tree; survive a deleted folder

- **Status:** Accepted
- **Date:** 2026-09-09
- **Deciders:** jka
- **Decision log:** AGENTS.md D89

## Context

After ADR-0088 a reopened project came back with its tree collapsed. Two edge cases also
needed answers: the project folder being deleted while rio runs, and the remembered
folder being gone at the next launch.

## Decision

- **The unfolded set is stored in the project's workspace session** (ADR-0031), beside
  the open files, not in `prefs.json`. It is project content, and storing it with the
  core means it also works with a remote core. `workspace.save` and `workspace.get`
  carry an `expanded` list, pruned of directories that no longer exist. It is saved on
  every fold and unfold. Sessions written before this change read as an empty set.
- **A project folder deleted during a run closes the project.** The files pane checks
  the root with one `fs.list`; on failure it clears the root and the unfolded set, shows
  the "no folder" placeholder without an error dialog, and forgets the reopen pointer if
  it named this root. A vanished subdirectory needs nothing, because its parent's
  listing no longer contains it.
- **A remembered folder gone at launch** is skipped and the pointer cleared.

## Alternatives considered

Deleting the orphaned session file when a project is forgotten. Not done: sessions are
keyed by path hash, so a recreated folder legitimately resumes, and deleting a
non-current project's session would require the frontend to name a root other than the
open one, which the workspace design forbids. The cost is one small file per project
ever opened.

## Consequences

- A project reopens with the tree as the user left it, locally and remotely.
- Deleting the project folder is handled quietly.
- A garbage collector for old session files would be a core-side addition if ever
  needed.
