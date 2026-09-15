# ADR-0073: Compare gets its own top-level menu

- **Status:** Accepted
- **Date:** 2026-09-08
- **Deciders:** jka
- **Decision log:** AGENTS.md D73

## Context

Compare With File… and Close Compare lived under View ▸ Editor Layout, beside Split
and Unsplit. Editor Layout arranges editor groups; Compare replaces the editor area
with a read-only diff (ADR-0028). Grouping them suggested Compare was a layout.

## Decision

Compare becomes a top-level menu after View, holding only the compare commands. A
short top-level menu is justified because the mode is otherwise reached only through
the agent's automatic compare or a file dialog; a named menu makes it discoverable.

## Consequences

- Editor Layout contains only group layout commands.
- The View menu is not lengthened.
- ADR-0074 added Compare With Another Tab… to this menu.
