# ADR-0001: Three layers: core, frontends, optional server

- **Status:** Accepted; amended by [ADR-0030](0030-always-a-channel-client.md)
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D1

## Context

rio is meant to be a small, readable IDE for a plain-text-editor, git and
AI-agent workflow. From the start it had three requirements that pull on the
structure of the program:

- a graphical frontend and a terminal frontend (in the way `emacs` and
  `emacs-nox` share one program), without duplicating logic between them;
- an optional server mode, where the editing state lives on another machine;
- source that stays small enough for one person to read, which means keeping
  toolkit code out of the logic.

## Decision

rio is split into three layers.

- **`rio-core`** is pure Tcl with no UI dependency. It holds all business
  logic: the document model, undo, file I/O, git, agent orchestration,
  project and session state, and command dispatch.
- **Frontends** (`rio-gui` in Tk, a later `rio-tui` in Ck) are thin. They render
  core state and turn user input into core requests. They contain no business
  logic.
- **Server mode** is the core running headless, reached by frontends over a
  transport rather than embedded in them.

The original sketch had the GUI call the core in-process and use a socket only in
server mode. ADR-0030 replaced that: a frontend is always a client to a core over
a channel. The three-layer split itself is unchanged.

## Consequences

- A second frontend, or a frontend in another language, needs no change to the
  core (see ADR-0002).
- New behaviour almost always belongs in the core, reached through an operation.
  Features that are implemented in the GUI need a stated reason (usually that they
  are pure presentation, as in ADR-0032 or ADR-0033).
- Anything headless (the core, the server, tests, verification probes) must stay
  free of Tk and exit explicitly. A `tclsh` that has loaded Tk waits in the event
  loop at end of input and maps an empty window.
- Every user action crosses the core boundary, which costs a round trip per edit
  (see ADR-0003 and ADR-0030).
