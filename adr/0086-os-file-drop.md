# ADR-0086: Drop a file on the window to open it, with optional tkdnd

- **Status:** Accepted
- **Date:** 2026-09-09
- **Deciders:** jka
- **Decision log:** AGENTS.md D86

## Context

Dragging a file from the operating system's file manager onto rio did nothing on
Windows or Linux. Opening a path was already supported; receiving the drop was not, and
plain Tk cannot do it. Drop reception exists only in the external `tkdnd` extension;
there is no pure-Tcl implementation (X11 would need the XDND protocol written by hand,
Windows an OLE shim). Earlier, internal tab dragging (ADR-0033) had been built without
`tkdnd`, but that gesture happens inside rio's own widgets, which Tk handles natively.

## Decision

`tkdnd` is an **optional** dependency: `set ::have_tkdnd [expr {![catch {package
require tkdnd}]}]`. Where it is installed, dropping files opens them (directories open
as projects); where it is absent, rio behaves exactly as before.

Drop targets are registered only for a **local** core. A dropped path is a path on the
GUI's machine and means nothing to a remote core, so with a remote core drops are not
accepted. Targets are registered on the top-level window and on each editor text
widget, because `tkdnd` does not pass drops to ancestors. Both call one handler.

## Consequences

- The hard dependencies stay Tk and `json` for the GUI (ADR-0115).
- INSTALL.md and WINDOWS.md document `tkdnd` as optional.
- Tests call the handler directly with a path list; a real drop cannot be generated
  headless.
- Uploading a dropped local file to a remote core, and non-file drops, are out of scope.
