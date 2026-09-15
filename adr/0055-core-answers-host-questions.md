# ADR-0055: Questions about the core's host are answered by the core

- **Status:** Accepted
- **Date:** 2026-09-03
- **Deciders:** jka
- **Decision log:** AGENTS.md D55

## Context

The remote file browser opened at `/` when it had nothing better to start from. That
is correct for a POSIX core and wrong for a Windows core, where the root is `C:/` and
`/` is not even an absolute path. Using the GUI's own root would be wrong the other
way round: a Windows GUI on a Linux core would offer `C:/`.

## Decision

`session.hello` reports **`fsroot`**, the root of the core's filesystem. The GUI
records it for each attachment and reads it again after reconnecting, since the new
core may be a different host. Further host facts can join it in the greeting when
needed.

General rule: if the answer depends on the core's host, ask the core.

## Consequences

- The field is additive and does not bump the protocol version. An older core omits
  it and the client keeps its default; an older client ignores it. The
  forward-compatibility rule of ADR-0019 applies to the protocol itself.
- The GUI still judges whether a path is absolute by its shape (a leading `/` or a
  drive prefix), not with Tcl's `file pathtype` or `file normalize`, which apply the
  client's rules. `fsroot` says where to start; the shape test says what an absolute
  path looks like.
- Later decisions follow the same rule: stale-buffer detection (ADR-0094) and TLS
  trust (ADR-0109) are decided on the core's host.
