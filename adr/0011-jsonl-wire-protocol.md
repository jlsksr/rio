# ADR-0011: Newline-delimited JSON wire protocol

- **Status:** Accepted; amended by [ADR-0113](0113-error-code-taxonomy.md)
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D11

## Context

ADR-0002 makes the core API a protocol. It needs a concrete encoding that any
language can speak, that a person can read while debugging, that maps cleanly
onto Tcl dicts, and that streams well.

## Decision

The protocol has three message kinds:

- **Request** (client to core): `{id, op, params}`
- **Response** (core to client): `{id, ok: true, result}` or
  `{id, ok: false, error}`, where `error` is `{code, message}` (ADR-0113).
- **Event** (core to clients, unsolicited): `{event, params}`, broadcast to every
  attached client.

Each message is one line of JSON (JSONL framing). JSON exists only at the channel
boundary; inside the core, operations call each other with plain Tcl dicts and
pay no serialisation cost.

A streaming operation acknowledges immediately and then emits a sequence of events
keyed by a run identifier, ending with a final event. `agent.send` is the first
such operation.

Operations are grouped in namespaces: `buffer.*`, `fs.*`, `project.*`, `git.*`,
`exec.*`, `agent.*`, `session.*`, and later ones added by individual decisions.
A client's first request is `session.hello`, which reports the protocol version,
the implementation name, the operations the core actually has registered (read
live from the dispatch table), and host facts such as `fsroot` (ADR-0055).

## Consequences

- Any language with a JSON library can be a client, which keeps ADR-0002's
  promise.
- Protocol messages are debuggable by eye.
- Tcl values carry no type, so encoding needs an explicit rule (ADR-0025).
- A breaking change to the wire format bumps the protocol version; adding a key
  does not. Clients ignore unknown keys and default missing ones.
- No operation holds its reply open for long. Long work streams as events, which
  is what lets the stale-link watchdog of ADR-0037 treat an overdue reply as a
  dead link.
