# ADR-0088: Reopen the last folder on launch

- **Status:** Accepted; amended by [ADR-0089](0089-remember-tree-shape.md)
- **Date:** 2026-09-09
- **Deciders:** jka
- **Decision log:** AGENTS.md D88

## Context

After opening a folder, quitting and relaunching, rio showed an empty files pane. The
core holds the open project in memory only, and the workspace restore of ADR-0031 is
keyed by that root, so a bare launch restored the anonymous session instead
(ADR-0072). Project resume only worked when the folder was given on the command line.

## Decision

The GUI remembers the last opened root in `prefs.json` (key `project`) and reopens it at
start-up, before the workspace restore, when the command line opened nothing.

- **Local cores only.** A project root is a path on the core's filesystem. With a remote
  core the GUI records nothing and reopens nothing, so a server path never replaces the
  remembered local one.
- **The core stays the owner.** If a persistent local core already has a project open,
  the GUI adopts it through `project.get` instead of overriding it.
- A remembered folder that no longer exists is skipped.

## Consequences

- A bare launch returns to the last project with its open files.
- The unfolded tree shape was not remembered at first; ADR-0089 added it.
