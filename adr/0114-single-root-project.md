# ADR-0114: A project is one root folder held by the core

- **Status:** Accepted
- **Date:** 2026-06-27
- **Deciders:** jka
- **Decision log:** AGENTS.md §6, O2 ("`project.*` — the workspace root")

## Context

Git operations relied on the core process's working directory, and the file tree and the
per-project `.rio/` directory needed an anchor. "The project" was an accident of how rio was
launched rather than an explicit fact.

## Decision

The core holds one canonical **project root** (`rio-core/project.tcl`).

- `project.open {path}` validates a directory, records its normalised absolute path, and
  emits `project.opened`, so every view resynchronises through one event.
- `project.get` returns the root, or an empty string when no project is open.
- `rio::project::resolve` defines what frontends mean by a path: empty is the root, relative
  is joined onto the root, absolute is used as given.
- `git.*` operations default their working directory to the root; `fs.list` lists relative
  to it; agent tools and commands are confined to it.
- A workspace is **single-root**, matching one folder and usually one git repository.

`fs.list {?path?}` lists one directory per call, dictionary-sorted, following symbolic links
for the type, and including dotfiles; hiding them is a frontend choice (ADR-0062). The
procedure is named `listdir` because a procedure called `list` would shadow Tcl's `list`
inside the namespace.

## Consequences

- The project is an explicit, queryable fact, and it lives with the core, so it is correct
  over a remote core.
- Sessions (ADR-0031), the last-folder pointer (ADR-0088) and project prompts and allow-lists
  key on it. With no project open, rio still works (ADR-0072).
- Multi-root workspaces are not supported. They could be added later without changing this
  interface.
