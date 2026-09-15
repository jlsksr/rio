# ADR-0005: The TUI is keyboard-only

- **Status:** Accepted, not implemented (the TUI is deferred, [ADR-0112](0112-tui-deferred.md))
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D5

## Context

Mouse support in terminals depends on the terminal emulator, the multiplexer and
their configuration, and is rarely exactly right. It is also the most
platform-sensitive part of Ck.

## Decision

The terminal frontend is driven by the keyboard only. It does not handle mouse
input.

## Consequences

- The most fragile part of Ck is outside rio's dependency surface.
- Every TUI action needs a key binding, which fits the keyboard-first workflow
  rio targets and the data-driven keymap of ADR-0023.
- The GUI is unaffected and uses the mouse normally.
