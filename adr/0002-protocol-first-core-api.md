# ADR-0002: The core API is a transport-independent message protocol

- **Status:** Accepted; amended by [ADR-0030](0030-always-a-channel-client.md)
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D2

## Context

ADR-0001 separates the core from its frontends and allows a server mode. If the
core were exposed as a set of Tcl procedures called directly by the GUI, server
mode would later need a second API and a second code path. The terminal
frontend also carries a risk: if the Ck toolkit proves unsuitable, the TUI may
have to be written in another language.

## Decision

The core exposes a request/response and event-stream API designed as a protocol
from the first day, independent of the transport that carries it. The same
requests are served whether the caller is in the same process or at the far end
of a socket.

The original plan shipped the in-process transport first. ADR-0030 removed the
in-process path for frontends: a frontend always speaks the protocol over a
channel. Inside the core, operations still call each other through the same
dispatch without serialisation.

## Consequences

- Server mode is the same core with a different transport, not a second
  codebase. This is what made ADR-0029 and ADR-0030 cheap.
- A frontend can be written in any language that can read and write the wire
  format (ADR-0011). If the Ck TUI fails, a TUI in another language can be built
  against the unchanged core, so the Ck spike gates Ck, not the project
  (ADR-0112).
- Every new operation has to be designed as structured data a terminal client
  could use, never as Tk-shaped payloads.
