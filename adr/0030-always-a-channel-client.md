# ADR-0030: The frontend is always a client over a channel

- **Status:** Accepted; amended by [ADR-0096](0096-rio-does-not-dial.md)
- **Date:** 2026-06-30
- **Deciders:** jka
- **Decision log:** AGENTS.md D30

## Context

After ADR-0029 the GUI had two transports: embedding the core, and a TCP socket.
Two paths for one job is redundancy, and the socket path had a security problem:
the agent was about to gain write and command-execution powers, and a loopback
socket without authentication is reachable by every user on a shared host. SSH
protects the network hop, not the loopback endpoints at either end.

## Decision

A frontend never embeds the core. It is always a client to a core at the far end
of a channel, and one client code path serves every channel kind:

- **Default: a pipe to a spawned child core** (`tclsh rio-core/server.tcl
  --stdio`). Requests go to its standard input; replies and events come from its
  standard output. No listening socket exists, so process ownership is the access
  control. Closing the channel ends the child.
- **`--connect host:port`: a TCP socket** to a listening core, for a persistent
  daemon serving one or more frontends. It binds loopback by default.

The agent runs in the core. Provider selection, keys and policy are operations
(`agent.provider.set`, `agent.key.set`, `agent.status`, …), providers register in a
named registry in `rio::agent`, and agent events are ordinary broadcast traffic.
API keys live in the core's secret store wherever the core runs.

Operational rules that followed:

- The first operation on any channel is `session.hello`, bounded at 8 seconds, so a
  dead tunnel that accepts connections but never answers produces an error instead
  of a blank window.
- On attach, the GUI reads the core's agent state and mirrors it; it writes state
  only on an explicit user action, so it never resets a daemon another client
  configured.
- File ▸ Connect to Remote Core… rewires the running window in place (open the new
  connection first, save-check open tabs, then swap), or opens a second window.
- With a remote core, the Open, Save As and Open Folder dialogs browse the core's
  filesystem over `fs.list`.

## Alternatives considered

- **Unix domain sockets.** Core Tcl (8.6 through 9.0) supports only TCP; AF_UNIX
  needs a compiled extension.
- **Loopback TCP with a capability token.** Workable, but adds an authentication
  protocol and token distribution.
- A pipe to a child needs no socket, no authentication and no cryptography, and uses
  only the standard library.

## Consequences

- Local and remote use are the same code, and the default configuration has no
  network surface.
- Every frontend-to-core call serialises, including locally.
- Each window has its own core unless it connects to a daemon.
- A headless core that runs the agent needs `tcltls`; the server deploy script
  installs it.
- The planned `--ssh` convenience wrapper (phase P4) was refused in ADR-0096. The
  remote path is `--connect` to whatever endpoint the operator has made reachable.
