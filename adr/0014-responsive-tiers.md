# ADR-0014: Responsive tiers and the unified-diff fallback

- **Status:** Accepted, not implemented (the TUI is deferred, [ADR-0112](0112-tui-deferred.md))
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D14

## Context

ADR-0009 places the layout rule in a shared function. The function needs concrete
outputs, and side-by-side diffs need a plan for screens too narrow to show two
columns.

## Decision

The layout function resolves to three tiers:

- **Wide:** `nav | editor | chat` as columns, one status line below. No bottom
  pane.
- **Mid:** one side column (the focused one) stays; the other collapses to a
  toggle.
- **Narrow:** a single column; nav and chat become collapsible sections stacked
  around the editor, and only expanded sections take height.

Two editor groups sit side by side when there is room. A side-by-side diff falls
back to a unified diff when the width is too small. Initial breakpoints are wide
at about 100 columns or more and narrow below about 70; the GUI maps window width
onto the same tiers.

## Consequences

- Diffs stay readable on small terminals, where the TUI has no mouse (ADR-0005).
- The tiers target the TUI. The GUI uses user-sized dock sites (ADR-0035) and
  shows the compare view side by side only (ADR-0028); the unified fallback is not
  built.
