# ADR-0075: A top-level Find menu

- **Status:** Accepted
- **Date:** 2026-09-08
- **Deciders:** jka
- **Decision log:** AGENTS.md D75

## Context

Find…, Replace…, Find Next, Find Previous and the project-wide Search… sat at the
bottom of the Edit menu, crowding the classic clipboard and selection commands.

## Decision

The whole group moves to a top-level **Find** menu, placed after View and before
Compare. Edit keeps Undo, Redo, Cut, Copy, Paste and Select All.

- The menu is named **Find**, not Search, because rio already has a Search pane and a
  Search… command; a Search menu would read as the same thing. Search… sits below a
  separator as the project-wide escalation, as in Sublime Text's Find menu.
- The entire group moves. Splitting find commands between two menus would be worse
  than either arrangement.

The menubar becomes File, Edit, View, Find, Compare, Settings, (later) Help.

## Consequences

- This departs from the Windows convention of Find under Edit; Sublime Text is the
  precedent.
- Labels, commands and accelerators are unchanged. The editor's context menu later
  brought the find commands back beside the edit actions for the selection
  (ADR-0108).
