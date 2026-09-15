# ADR-0010: Asynchrony through the event loop and coroutines

- **Status:** Accepted
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D10

## Context

Several operations take time: streaming model output, running git or other
commands, and waiting on the network. Tcl is single-threaded by default, and the
UI must never freeze while such work runs.

## Decision

Long operations use Tcl's event loop: `fileevent` for channel readiness and
coroutines (Tcl 8.6+) to keep sequential logic readable. rio does not use threads.

Examples in the code base: the agent loop runs each turn in a coroutine that
yields at the approval gate and while waiting for a provider (ADR-0026,
ADR-0104); command execution for the agent is asynchronous with a timer-driven
timeout (ADR-0083); the GUI reads the core channel with a `fileevent` reader
(ADR-0030).

## Consequences

- Streaming code reads as a straight sequence rather than as callbacks.
- Anything that blocks the interpreter (a synchronous `exec`, a synchronous HTTP
  fetch) blocks every client of that core. Such calls must stay short or be made
  asynchronous; the agent's command tool had to become asynchronous for exactly
  this reason.
- Nested event loops need care. `vwait` inside a `fileevent` handler, or starting
  a core call from inside another call's round trip, causes re-entrancy bugs;
  several later decisions defer work to idle or timer callbacks for this reason.
