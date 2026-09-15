# ADR-0096: rio speaks the protocol; it does not dial

- **Status:** Accepted
- **Date:** 2026-09-11
- **Deciders:** jka
- **Decision log:** AGENTS.md D96

## Context

ADR-0030 left a pending phase: an `--ssh host [path]` wrapper that would open a tunnel
and attach in one step. The maintainer rejected it: people reach a core in many ways
(`ssh -L`, Tailscale, WireGuard, a VPN, a bastion host), rio should not predict which,
and it should be network-transparent in the way X11 is.

X11 does not know what SSH is. `ssh -X` is SSH's feature: SSH opens a listener and sets
`DISPLAY`. X's contract is only that a display string names an endpoint and X speaks its
protocol over whatever byte stream it is given.

## Decision

rio speaks its protocol over a byte stream; how that stream reaches the core is the
operator's business. The `--ssh` wrapper is refused as a category, not deferred, and the
channel-transport plan is closed at its third phase.

`--connect host:port` already fulfils the requirement: every tunnel, overlay network and
VPN ends in a host and a port. Future proposals shaped like "rio helps you reach a
core" (tunnel helpers, connection managers, discovery) are out of scope by decision.

## Alternatives considered

**`--core-cmd <command>`**, where the operator names a command whose standard streams
become the channel (`ssh host … --stdio`, `kubectl exec -i`, `socat`), in the style of
git's `GIT_SSH_COMMAND` and LSP client commands. It was built, tested and committed, then
reverted at the maintainer's request: rio already had one way to reach a remote core, and
a second mechanism for the same job contradicts the same simplicity argument that refused
`--ssh`.

## Consequences

- There is nothing to maintain for any particular tunnel technology.
- rio cannot be used remotely without a listening core. A private remote core over a
  pipe, with process ownership as access control, is a real gap. The `--core-cmd` design
  above is how to close it if someone needs it.
- While a socket is the only remote transport, the GUI's `::core_remote` flag stands
  for two facts: the transport is a socket, and the core's filesystem is not the GUI's.
  Anything that makes a pipe remote must first split it, as the reverted change did with
  `::core_transport` (`pipe` or `socket`). Otherwise the stale-link watchdog
  (ADR-0037), which is meant for sockets only, would arm against a pipe.
