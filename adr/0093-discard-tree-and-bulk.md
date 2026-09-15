# ADR-0093: Discard from the file tree, and discard all

- **Status:** Accepted
- **Date:** 2026-09-10
- **Deciders:** jka
- **Decision log:** AGENTS.md D93

## Context

Discard (ADR-0080) was reachable only from the git pane, one file at a time.

## Decision

**From the file tree.** The tree's row menu offers Discard Changes… for tracked changes.
It uses the same confirmation as the git pane and quotes the repository-relative path.
It is not offered for untracked files or staged additions, because the tree's own
Delete… already removes them and two identically labelled entries in one menu would be
confusing.

**Discard all** is one core operation, `git.discard_all`, not a loop in the GUI:

- If HEAD exists: `git reset -q --hard`. If the repository has no commits:
  `git reset -q`.
- Then `git clean -fd -- :/`, sweeping untracked files across the whole repository.
- No `-x`: ignored files survive. Build output or a local `.env` was never in the list
  of changes the user saw.
- It returns the number of changed paths, so the confirmation reports what the core
  acted on.

The control is a `↩` button in the git pane header, shown only while the repository has
changes, following the commit bar's rule (ADR-0045). The confirmation names both effects
(changed files revert, never-committed files are deleted), states that ignored files are
untouched, and defaults to No.

## Alternatives considered

- A GUI loop over `git.discard`: one round trip per file over a possibly remote channel,
  and a dropped connection mid-loop leaves a half-discarded tree.
- A menu entry at the foot of the git row menu: row menus hold actions about their row
  (ADR-0044), and the entry would be unreachable when the pane shows a placeholder.

## Consequences

- Deleting a staged addition with the tree's fs Delete leaves an index entry; the git
  pane's own Delete… recovers it.
- Discard all can rewrite many files under open buffers at once, which made ADR-0094
  necessary.
