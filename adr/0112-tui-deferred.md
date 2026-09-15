# ADR-0112: The TUI is deferred after a successful Ck spike

- **Status:** Accepted
- **Date:** 2026-06-27
- **Deciders:** jka
- **Decision log:** AGENTS.md §6, O1; `spike/probes/VERDICT.md`

## Context

ADR-0004 chose Ck for the terminal frontend, with an open question: can Ck carry an
editor TUI? A throwaway spike was specified with six pass/fail criteria: build and run,
the text widget as a code editor, layout reflow on terminal resize, keyboard coverage,
Unicode, and redraw correctness. A second question was when to build the TUI: two
frontends kept in step over a protocol that is still changing double the work of every
change.

## Decision

The spike was run against `vzvca/ck8.6` at commit `1a991e3` with Tcl 8.6.16 and ncursesw
6.5. Results:

- **Pass:** builds (with legacy C flags under GCC 14); the `text` widget handles a
  5000-line buffer with scrolling, editing and foreground-colour tags; layout reflows on
  resize; BMP Unicode including box drawing and wide CJK renders; redraw is clean.
- **Findings:** Ck has no `<Configure>` event. It reports resizes through `<Expose>`, and
  re-layout must be guarded by an actual width change to avoid a loop.
- **Weak:** keyboard. In tmux every chord arrived; on a plain Debian terminal only Ctrl+A
  reached the application. Cross-terminal key handling is real work, and Cygwin was not
  tested.

On that basis **the TUI is deferred** to a separate, later effort, which may be done by
someone else. It is not active work. Core and GUI are the focus.

## Consequences

- The protocol (ADR-0002, ADR-0011) remains the public contract, so a TUI or any other
  client can attach later without core changes.
- Every new operation is designed as structured data a terminal client could use.
- The spike and its verdict are the starting kit for whoever builds the TUI. If Ck's
  keyboard handling cannot be made good, the fallback is a TUI in another language against
  the same protocol.
- TUI-only decisions (ADR-0005, ADR-0006, ADR-0009, ADR-0014) remain accepted but
  unimplemented.
