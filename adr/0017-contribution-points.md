# ADR-0017: Contribution points for extensions

- **Status:** Accepted, not implemented (the general plugin platform is deferred)
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D17

## Context

Given the plugin model of ADR-0016, rio needs a defined surface of things a
plugin may add, so the core can stay minimal and the extension story is not an
afterthought.

## Decision

A plugin may register:

- **commands** (for a command palette and key bindings);
- **key bindings**;
- **event subscriptions** (buffer, save, git and similar events);
- **providers**: formatter, linter or diagnostics, syntax highlighter, LLM
  provider, version-control backend;
- **UI contributions**, declaratively (ADR-0018).

Buffer and text manipulation reuse the existing `buffer.*` operations. rio ships
some first-party plugins on the same API to keep it proven in use; even syntax
highlighting or an LSP bridge may be plugins rather than core.

## Consequences

- The core stays small and the plugin API is the extensibility story.
- Until the platform is built, individual contribution kinds ship on dedicated,
  simpler seams: highlighters (ADR-0032), editing modes (ADR-0038), themes
  (ADR-0024), providers (ADR-0066). These are designed so a later general platform
  can absorb them.
