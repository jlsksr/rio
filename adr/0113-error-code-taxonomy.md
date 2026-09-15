# ADR-0113: A small, stable error-code taxonomy

- **Status:** Accepted
- **Date:** 2026-06-26
- **Deciders:** jka
- **Decision log:** AGENTS.md §6, O2 ("Error taxonomy")

## Context

ADR-0011's first responses carried `error` as a bare string. Clients could display it but
not act on it, and an uncaught Tcl error risked reaching a client as a stack trace. The GUI
also read `result` without checking `ok`, and crashed on a failed operation.

## Decision

An error reply's `error` is an object `{code, message}`: a stable, machine-readable code
that clients branch on, and a human message for display.

The vocabulary is deliberately small:

| Code | Meaning |
| ---- | ------- |
| `bad_request` | The request is invalid, or the operation refused it (including git's own refusals). |
| `unknown_op` | No such operation. |
| `no_buffer` | The buffer id does not exist. |
| `no_path` | A save needs a path and the buffer has none. |
| `bad_index` | A `line.col` index is out of range or malformed. |
| `io_error` | A filesystem, launch or network failure. |
| `untrusted_cert` | The core refused a TLS certificate; the client may offer a review (ADR-0111). |
| `internal` | Any uncaught error, so a defect still produces a clean reply. |

An operation raises `rio::error::raise <code> <message>`, which carries the code in Tcl's
`-errorcode`; dispatch shapes the reply. Changing `error` from a string to an object bumped
the protocol version to 2.

## Consequences

- The GUI checks `ok` before reading `result` and reports failures through one
  `report_error` path.
- A new code is added only when a client needs to act differently;
  `untrusted_cert` (2026-09-15) is the only addition so far.
- A test holds the vocabulary, so a new code cannot be added silently.
