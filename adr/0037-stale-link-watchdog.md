# ADR-0037: Stale-link detection at the protocol layer

- **Status:** Accepted
- **Date:** 2026-07-12
- **Deciders:** jka
- **Decision log:** AGENTS.md D37

## Context

A GUI attached to a remote core through an `ssh -L` tunnel lost the tunnel. The
socket stayed half-open: writes succeeded into the kernel buffer, but no replies
and no end-of-file arrived. Clicks did nothing, and only after five to ten minutes
did TCP give up. The question was whether rio could notice sooner without adding
socket options, keepalives or platform-specific code.

## Decision

The GUI runs a watchdog built from pieces the protocol already had: the bounded call
timer, `session.hello` as a ping, and the existing teardown path. Every 10 seconds
it checks:

1. **An overdue reply:** a call pending longer than 25 seconds. No rio operation
   legitimately holds its reply open, because streaming operations acknowledge
   immediately and continue with events (ADR-0011).
2. **An idle probe:** if nothing is pending and nothing has arrived for a full
   interval, one `session.hello` bounded at 8 seconds. Any received line, including
   streaming events, counts as life.

Either finding tears down the connection with a message that names the likely cause
and the remedy: re-establish the tunnel, then File ▸ Connect to Remote Core… with
the last endpoint prefilled.

The watchdog is armed only for socket connections. A pipe to a spawned core
delivers end-of-file as soon as the child exits, so the half-open case cannot
occur there. rio does not reconnect automatically.

## Consequences

- A stale link is reported within about 35 seconds when idle and about 25 seconds
  after a click.
- The thresholds are plain variables, so tests can shrink them.
- Automatic reconnection is left out because the tunnel must return first, and
  silently re-attaching raises questions about unsaved buffers that the explicit
  reconnect already handles with the user present.
- The watchdog is keyed on "socket transport". While a socket is the only remote
  transport, the GUI's single "remote core" flag can stand for both "socket" and
  "not my filesystem". Anything that makes a pipe remote must split the flag first
  (ADR-0096).
