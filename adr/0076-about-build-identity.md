# ADR-0076: About rio shows the build's commit identity

- **Status:** Accepted
- **Date:** 2026-09-08
- **Deciders:** jka
- **Decision log:** AGENTS.md D76

## Context

rio has no release version yet; the first alpha tag is a release gate in
RELEASING.md. Testers still need to state exactly which build they run.

## Decision

A **Help** menu, last in the menubar, contains **About rio**. The dialog shows the
build identity from `git describe --tags --always` and the commit date, both read from
rio's own source directory, plus the protocol version. The values are computed on first
use and cached; a checkout without git shows "unknown".

The GUI runs git directly here, rather than through the core's `git.*` operations,
because this is a fact about the local installation, not about the user's project, and
the core may be a different build on another machine.

## Consequences

- Once a release is tagged, the tag appears instead of the commit hash with no change.
- Nothing runs at start-up.
