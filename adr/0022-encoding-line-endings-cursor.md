# ADR-0022: Preserve encoding and line endings; cursors are frontend-local

- **Status:** Accepted
- **Date:** 2026-06-25
- **Deciders:** jka
- **Decision log:** AGENTS.md D22

## Context

An editor used on real repositories across platforms must not rewrite files it
did not mean to change. Silent CRLF conversion is a classic source of diff noise.
Separately, the protocol needs a rule for cursor and selection state now that the
document lives in the core (ADR-0003).

## Decision

- **Encoding:** UTF-8 by default. On open, the file's encoding is detected; on
  save, it is preserved. A byte-order mark, if present, is kept.
- **Line endings:** the file's convention (LF or CRLF) is detected and preserved.
  New files use LF. A file with mixed endings keeps its dominant style; rio never
  normalises silently.
- **Cursor, selection and viewport belong to the frontend.** The protocol carries
  edits as ranges (ADR-0012), never "where the cursor is".

Detection is bounded: UTF-8 with or without BOM, validated per RFC 3629, with a
lossless ISO-8859-1 byte fallback; LF and CRLF. UTF-16, bare CR, and lazy loading
of large files are out of scope. The detected encoding, BOM and line ending travel
as buffer metadata so a save reproduces the on-disk form.

## Consequences

- rio can be trusted with existing files on every platform.
- Two frontends, or two views of one buffer, move their cursors independently
  without round trips.
- Features that need the cursor (find, undo grouping) must either receive the
  position from the frontend as a parameter or avoid needing it. ADR-0036 and
  ADR-0090 were designed around this.
