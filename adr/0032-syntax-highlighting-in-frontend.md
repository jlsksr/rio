# ADR-0032: Syntax highlighting: swappable per-line scanners in the frontend

- **Status:** Accepted
- **Date:** 2026-07-01
- **Deciders:** jka
- **Decision log:** AGENTS.md D32

## Context

rio needed syntax highlighting that harmonises with themes, uses no external
packages, and lets one language's highlighter be replaced without touching the
rest. Highlighting could run in the core, which would give every frontend
highlighting for free, or in the frontend.

## Decision

Highlighting is presentation and lives in the frontend. The split mirrors themes
(ADR-0024):

- **The core owns the colours**, as `syntax.*` roles in the theme role table
  (`syntax.comment`, `syntax.string`, `syntax.keyword`, …). A theme harmonises
  highlighting through ordinary role values; a theme that predates the roles
  inherits the defaults.
- **The frontend owns the tokenisers and the applier.** A highlighter is a pure,
  Tk-free Tcl module in `syntax/<lang>.tcl` that implements a per-line scanner:
  `scan {line state param} → {spans nextstate nextparam}`, returning `line.col`
  spans and the state entering the next line. The GUI tags each span with the
  theme colour for its token type.

Highlighters register through `syntax/registry.tcl` by extension (and by file name,
ADR-0046) with a human-readable language name. Shipped modules load first, then
modules from `$XDG_CONFIG_HOME/rio/syntax/`; a later registration wins. A broken
module is reported and skipped.

The GUI re-highlights incrementally: it caches the scan state entering each line,
rescans from the first changed line, and stops once a line's fresh entry state
matches the cached one. Only the scan on opening a file covers the whole buffer.
The status bar shows the active language or "plain text".

The design rule for every language: where a token's meaning depends on position or
is ambiguous, colour only what is unambiguous and leave the rest plain. Examples:
`#` is a comment only in command position in Tcl and shell; regex literals in
JavaScript and bare `/regex/` in Perl are not recognised because `/` may be
division.

## Alternatives considered

Tokenising in the core and broadcasting spans with `buffer.changed`. Rejected: it
puts a network round trip in front of colour, which is visibly slow over a remote
core, and adds span encoding and viewport plumbing to the core for a pure function
that needs no core state.

## Consequences

- Colouring is immediate, harmonises with every theme, and a language can be added
  or replaced by dropping in one file.
- Tokenisers are testable under plain `tclsh` (`syntax/tests/all.tcl`) and reusable
  by a future TUI with its own applier.
- A remote-core user gets highlighting from the GUI's own modules, not the server's.
- Viewport-limited highlighting is deferred until very large files cause real
  problems.
- Highlighters are Tcl code that runs in the editor; installing one from a
  repository is presented as installing code (ADR-0039).
