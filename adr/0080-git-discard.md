# ADR-0080: Git discard for everyday use

- **Status:** Accepted; amended by [ADR-0093](0093-discard-tree-and-bulk.md), [ADR-0097](0097-rename-aware-discard.md)
- **Date:** 2026-09-08
- **Deciders:** jka
- **Decision log:** AGENTS.md D80

## Context

rio could stage, unstage and commit. The missing everyday operation was "throw away
my changes to this file", aimed at users with basic git knowledge: one safe, obvious,
confirmed action per file.

## Decision

Discard has one meaning: make this file match the last commit, and if it is not in the
last commit, remove it. `rio::git::discard` chooses by the file's staged status:

- **Tracked change:** `git restore --staged --worktree -- <path>`, reverting both
  staged and unstaged edits.
- **New file** (untracked, or a staged addition): remove it (`git reset` first for a
  staged addition, then `git clean -fd`).
- **No change:** `bad_request`.

`restore --staged` is safe here, unlike in ADR-0044's unstage, because this branch only
runs for files with a committed version, so HEAD exists.

`git.discard {path}` returns the action taken. The git pane's row menu shows
"Discard Changes…" for a tracked change and "Delete…" for a new file, behind a
confirmation whose default is No. The core decides the action and returns it, so the
wording and the effect cannot diverge.

## Consequences

- Discard is a single, understandable action, and new files are handled consistently.
- The first version was reachable only from the git pane, one file at a time, and did
  not handle renames; ADR-0093 and ADR-0097 closed those gaps.
- Discard rewrites files under open buffers, which led to ADR-0094.
