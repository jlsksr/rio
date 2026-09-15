# ADR-0029: The GUI can drive a remote core over a socket

- **Status:** Superseded by [ADR-0030](0030-always-a-channel-client.md)
- **Date:** 2026-06-30
- **Deciders:** jka
- **Decision log:** AGENTS.md D29

## Context

A socket server for the core already existed and was tested, but the GUI embedded
the core and called it in-process. There was no client, so the core could not be
used from another machine.

## Decision

The GUI gained a remote mode behind a single call seam. `--connect host:port` (or
`RIO_CONNECT`) selects it before any code is sourced. In remote mode the GUI loads
only the wire encoder, writes requests with unique ids, and a `fileevent` reader
routes events to one `dispatch_event` procedure and replies to the call waiting on
that id. A dropped socket wakes every pending call with a `disconnected` error.

Supporting changes:

- The GUI stopped reaching past the protocol (`buffer.text` and `buffer.list`
  replaced direct calls into core namespaces).
- File choosers browse the server's filesystem in remote mode, first through a
  typed path and later through a point-and-click browser over `fs.list`.
- The server binds 127.0.0.1 unless told otherwise, and prints a warning when bound
  to all interfaces. It has no authentication or encryption; those are left to SSH.

## Consequences

- The wire layer was exercised end to end from a real GUI for the first time.
- The GUI now had two transports, in-process and socket. ADR-0030 removed that
  redundancy by making the GUI always a channel client.
- Each keystroke costs one round trip over the network.
