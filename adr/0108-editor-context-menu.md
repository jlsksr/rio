# ADR-0108: The editor has a context menu built from the Edit menu's table

- **Status:** Accepted; amended by [ADR-0121](0121-context-menu-outside-the-editor.md)
- **Date:** 2026-09-12
- **Deciders:** jka
- **Decision log:** AGENTS.md D108

## Context

Right-clicking the text did nothing, although the panes and tabs had context menus. The
actions needed (clipboard, undo, select all, find) already existed as shared procedures.

## Decision

The editor gets a right-click context menu containing the Edit menu's actions and the find
commands. It applies to the editor only; read-only views (agent log, compare panes, git diff,
manual) are a later change.

- **One table for both menus.** `editor_menu_items` returns the Edit actions as
  `{label command accel state}`. The menubar's Edit menu and the context menu are both built
  from it, and the Edit menu recomputes enabled states each time it is posted.
- **Only states rio can compute are greyed.** Cut and Copy follow the selection; Select All
  follows an empty buffer. Undo and Redo stay enabled, because the history is in the core and
  there is no query for it. Paste stays enabled, because probing the clipboard is a blocking
  X request to whichever application owns the selection.
- **The click prepares the target.** A click inside the selection keeps it; a click elsewhere
  clears it and moves the caret to the clicked character, so Paste lands there. The click also
  focuses its editor group, because Tk moves focus only on button 1 and every command acts on
  the focused group.
- **Find entries.** The label reads `Search for "needle"` for a usable single-line
  selection (shortened after 20 characters) and `Search…` otherwise, matching what the
  commands actually seed.
- The binding is on the widget, ahead of the editing-mode tag, and ends with `break`, so it
  wins over any mode. The Menu key and Shift+F10 open the same menu at the caret.

## Consequences

- The menubar and the context menu cannot drift apart.
- The items `docs/editor.md` lists are checked against the real menu in both directions
  (ADR-0117).
