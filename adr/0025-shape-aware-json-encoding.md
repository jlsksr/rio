# ADR-0025: JSON encoding is shape-aware, never value-sniffed

- **Status:** Accepted
- **Date:** 2026-06-25
- **Deciders:** jka
- **Decision log:** AGENTS.md D25

## Context

Inside the core, values are Tcl dicts and strings (ADR-0011). Tcl cannot tell the
string `"hi there"` from the two-element list `{hi there}`, or the string `"10"`
from a number. A generic dict-to-JSON encoder must therefore guess types from
values, which mis-types strings that happen to look like lists or numbers.

## Decision

The boundary encoder never infers types from values.

- The envelope is fixed: `id` is a JSON string, `ok` is a JSON boolean, and a reply
  carries either `result` or `error` (`{code, message}`).
- `result` and event `params` default to flat objects whose values are JSON
  strings.
- An operation that needs another shape (numbers, arrays, nested objects)
  declares it: `rio::wire` keeps a result-encoder registry keyed by operation
  name, and dispatch passes the operation name with the reply. Unregistered
  operations use the flat encoder.
- Inbound JSON is parsed with tcllib's `json::json2dict`.
- `rio::wire::str` escapes every C0 control character, as RFC 8259 requires.

## Consequences

- Encoding is total and predictable, and each non-flat result is explicit in
  `rio-core/wire.tcl`.
- A registered encoder lists its keys by name, so a key added to an operation's
  result is dropped on the wire unless the encoder is updated. Core tests that call
  the operation directly do not notice. Since ADR-0110, each encoder has a guard
  test that encodes the real operation's result and compares the key set.
- Events are flat objects. An event that would need nested data carries an
  identifier instead, and the client fetches the data (ADR-0106).
