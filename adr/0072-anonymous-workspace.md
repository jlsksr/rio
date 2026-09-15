# ADR-0072: A session for work with no project open

- **Status:** Accepted
- **Date:** 2026-09-08
- **Deciders:** jka
- **Decision log:** AGENTS.md D72

## Context

ADR-0031 resumes a workspace per project root, and with no project open the workspace
operations did nothing. That left a real workflow unremembered: one long-running rio
used as a daily notebook, with many tabs from unrelated folders.

## Decision

An empty project root selects an **anonymous session**, stored in the reserved file
`sessions/anonymous.json`, which cannot collide with a project's md5-named file.
`workspace.save` and `workspace.get` accept the empty root. The GUI already saved and
restored sessions unconditionally, so only the core changed.

## Consequences

- A bare `rio-gui` launch restores its loose files.
- The anonymous session lives with the core, so it also follows a remote core.
- There is a single anonymous session. Two simultaneous windows with no project
  overwrite each other's session. This is acceptable for the one-daily-instance
  workflow and recorded in CAVEATS.md; project sessions stay isolated.
- Reopening the last project folder was a separate decision (ADR-0088).
