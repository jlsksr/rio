# ADR-0057: Tab overflow: page, wrap, or list

- **Status:** Accepted; amended by [ADR-0074](0074-buffer-picker.md), [ADR-0078](0078-multi-line-tab-rows.md)
- **Date:** 2026-09-03
- **Deciders:** jka
- **Decision log:** AGENTS.md D57

## Context

In a narrow window, tabs beyond the right edge of a group's strip could not be
reached, a long-standing complaint about Notepad++ as well.

## Decision

Three complementary mechanisms:

- **A list of every open buffer**, always reachable. It was first a top-level Tabs
  menu; ADR-0074 replaced it with a bounded picker dialog, View ▸ Switch to Tab….
- **Scroll mode** (default): tabs stay on one line, and when they overflow, `◂ ▸`
  arrows page a visible window of tabs. Activating a tab scrolls it into view; the
  arrows can page past the active tab.
- **Multi-line mode:** tabs wrap onto as many rows as needed.

The mode is a persisted View preference (`tab_layout`). One procedure,
`tabstrip_layout`, places the tab handles and runs again on resize. Tab widths are
computed from font metrics rather than read from mapped widgets, so layout is correct
immediately and testable without a display.

## Consequences

- Every tab is reachable at any window width.
- The Multi-Line Tabs toggle first lived in the Tabs menu. That mismatch, a view
  preference inside a navigation list, prompted the Preferences window (ADR-0058).
- Multi-line layout was reworked in ADR-0078 after the first version, built with
  `grid`, left gaps and clipped tabs.
