# ADR-0013: Fixed layout regions and a collapsible section stack

- **Status:** Accepted; amended by [ADR-0035](0035-tool-windows-dock-sites.md)
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D13

## Context

rio's screen needs a familiar arrangement that both a GUI and a terminal can
render, and that can collapse on narrow displays without a second design.

## Decision

The layout has a fixed set of logical regions:

- **nav** (left): files and git.
- **editor** (centre): tabbed, splittable into two editor groups.
- **chat** (right): the agent conversation, its input, and proposed edits.
  Command output the agent needs to show appears here; there is no terminal
  region (ADR-0015).
- **status** (bottom): a single always-present line.

One UI primitive, a collapsible section stack, backs both the left navigation and
the narrow-mode collapse of all side panes. Layout is adjustable (visibility and
sizes are remembered) but not free-form in the first version.

## Consequences

- Users coming from VS Code-like editors recognise the arrangement.
- The GUI later replaced the fixed nav/chat regions with dock sites that any tool
  panel can move between (ADR-0035). The editor and status regions, and the rule
  that there is no terminal region, are unchanged.
- The collapsible section stack is a TUI concern and has not been built.
