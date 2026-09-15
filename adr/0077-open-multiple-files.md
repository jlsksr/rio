# ADR-0077: Open several files from the native chooser

- **Status:** Accepted
- **Date:** 2026-09-08
- **Deciders:** jka
- **Decision log:** AGENTS.md D77

## Context

The Open File dialog allowed one file: `tk_getOpenFile` is single-select by default,
so Ctrl- and Shift-selection did nothing on Linux and Windows.

## Decision

The local Open dialog passes `-multiple 1` and opens each returned path. Opening
de-duplicates against open buffers and activates the file, so the last selected file
ends up focused.

The remote file browser used with a remote core stays single-select; extending it is
a separate change.

## Consequences

- Tests stub `tk_getOpenFile` and must force the local branch, because the test core is
  attached over a socket and the remote branch is a modal dialog.
