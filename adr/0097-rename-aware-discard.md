# ADR-0097: Discarding a rename restores the old name

- **Status:** Accepted
- **Date:** 2026-09-11
- **Deciders:** jka
- **Decision log:** AGENTS.md D97

## Context

A rename is the one change git records as one entry with two names. Discard (ADR-0080)
treated it as a change to the new name only: `git restore --staged --worktree -- new.txt`
dropped the index entry and left the file untracked, and the old name stayed deleted.
The rename was unstaged, not undone. The cause was the query: git's rename detection
needs both paths in the same diff, and a status narrowed to the new path reports a plain
addition.

## Decision

- `rio::git::discard` reads the full repository status and finds the entry, instead of
  querying the single path.
- For a rename (`R`): unstage both paths, restore the old name from the index into the
  working tree, then remove the new file with `git clean`.
- A copy (`C`) is handled as an addition: the new file is removed and the source is
  untouched.
- The function returns `{action, paths}`, so the operation emits `fs.changed` for both
  names (ADR-0094).
- In the git pane, the confirmation for a rename says the file will go back to its old
  name and last committed contents. The file tree's entry keeps the generic wording,
  because its rows do not carry the original path.
- `git.diff` uses the same full-status lookup for staged renames and passes git both
  names, so a rename shows as a rename rather than as a new file. Unstaged diffs are
  unaffected.

## Consequences

- Discard undoes a rename completely.
- The core is the authority on what a change is. A second frontend gets a correct diff
  and discard without knowing about renames.
- Clicking a staged row costs one full `status` call. The unstaged path does not.
