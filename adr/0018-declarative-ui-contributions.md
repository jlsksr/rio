# ADR-0018: UI contributions are declarative

- **Status:** Accepted, not implemented (the general plugin platform is deferred)
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D18

## Context

A plugin that draws its own Tk widgets would not work in the Ck TUI, and a plugin
author should not need to know which frontend is running. This is the hardest part
of any plugin system that spans more than one frontend.

## Decision

Plugins contribute structured, semantic UI, such as "add a navigation section
showing this tree", "add a status item", "decorate these ranges", or "add a panel
with this list". They never supply raw Tk or Ck widget code. Each frontend renders
the same declarative contribution in its own toolkit.

## Consequences

- Plugins stay portable and GUI/TUI parity is preserved by construction.
- The concrete schema and vocabulary for declarative UI are still open.
- The model is unsuitable for behaviour that runs on every keystroke. Editing
  modes were therefore given their own frontend-code seam instead (ADR-0038).
- The dock-site system (ADR-0035) is the intended render target for a
  plugin-contributed panel.
