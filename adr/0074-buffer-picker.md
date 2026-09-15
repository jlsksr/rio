# ADR-0074: A bounded buffer picker replaces the Tabs menu

- **Status:** Accepted; generalised by [ADR-0092](0092-theme-picker.md)
- **Date:** 2026-09-08
- **Deciders:** jka
- **Decision log:** AGENTS.md D74

## Context

Two gaps had the same shape. Compare could only diff the active buffer against a
file on disk, while the more common need was comparing against another open tab. And
the Tabs menu (ADR-0057) listed every open buffer: it had no size limit, so it could
exceed the screen height on X11 (ADR-0064), and it showed only file names, so two
tabs with the same name were indistinguishable.

## Decision

Both needs use one **modal picker dialog**: a themed window with a list and a
scrollbar that hides when not needed; double-click or Return chooses; Escape cancels.
Each row shows the tab name, the unsaved marker, and the parent directory as a hint.
The row list is built by a separate procedure so it can be tested without the dialog.

- The Compare menu leads with **Compare With Another Tab…**, comparing live buffer
  text on both sides, followed by Compare With A File… and Close Compare.
- The **Tabs menu is removed.** View ▸ Switch to Tab… opens the same picker and
  activates the chosen buffer.

## Consequences

- No data-driven menu with unbounded length remains except the Theme menu, which
  followed in ADR-0092 using the same dialog.
- Same-named tabs can be told apart.
- Switch to Tab… has no keyboard shortcut yet.
