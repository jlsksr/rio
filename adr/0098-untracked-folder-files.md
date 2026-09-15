# ADR-0098: Files inside an untracked folder can be tracked individually

- **Status:** Accepted
- **Date:** 2026-09-11
- **Deciders:** jka
- **Decision log:** AGENTS.md D98

## Context

A user wanted to stage one new file inside a new folder and found no menu item for it.
`git status --porcelain` collapses a wholly untracked directory into one `sub/` entry and
lists nothing beneath it. The git pane therefore had no row for the file, and the file
tree treated "not in the status map" as "clean" and offered no git actions.

## Decision

- **The file tree offers Track (git add) for such a file.** When a file has no status
  entry, the tree checks whether an ancestor is listed as untracked. After the first
  `git add`, git lists the folder's remaining files individually, so the fallback is only
  needed once.
- **The git pane still mirrors git's status output.** It does not invent rows for files
  git did not list. Its folder row drops Open, which cannot open a directory, and is
  labelled Stage folder, as in the tree.

## Consequences

- Any file the tree shows can be tracked.
- The git pane's counts, bulk discard and diff always describe what git reports.
- A file under tracked ancestors is still treated as clean; a test guards against an
  over-eager ancestor match adding Track to every row.
