# ADR-0046: Highlighters can register by file name

- **Status:** Accepted
- **Date:** 2026-08-10
- **Deciders:** jka
- **Decision log:** AGENTS.md D46

## Context

The highlighter registry (ADR-0032) resolved a language by file extension only.
Common build files have no extension (`Makefile`, `Dockerfile`), so they could not be
highlighted.

## Decision

`register_filename <lang> {basenames} <scan>` maps whole file names to a scanner,
beside the extension map. Resolution order is:

1. exact file name;
2. extension;
3. file name with its last suffix removed (so `Dockerfile.prod` resolves).

An explicit extension always wins over the stripped-name guess, so `Makefile.tcl` is
Tcl. Matching is case-insensitive, and a later registration still wins.

## Consequences

- Makefile, Dockerfile, batch, PowerShell, awk and sed highlighters became useful.
- A language may register under both keys (Makefile by name and by `.mk`).
- Shebang detection (`#!/usr/bin/awk`) is not implemented and would be the next
  step.
