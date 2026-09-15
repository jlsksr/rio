# ADR-0003: The core owns the document; frontends are views

- **Status:** Accepted
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D3

## Context

Tk's `text` widget is a capable editing surface with its own undo, marks and
tags. The simplest editor would keep the buffer in the widget. That model breaks
as soon as the buffer must live elsewhere: on a server, or shown by two
frontends at once.

## Decision

The document of record lives in the core. A frontend is a view onto it. An edit
in a widget becomes an edit request; the core applies it and broadcasts the
change; every view, including the one that originated the edit, updates from
the broadcast.

The Tk `text` widget is a display surface. rio uses its tags for highlighting
and diff colouring, but never treats its contents as the source of truth.

## Consequences

- Server mode, several views of one buffer, and GUI and TUI side by side all use
  one buffer implementation.
- In the GUI a keystroke is a `buffer.replace` request, and the character appears
  when `buffer.changed` comes back. Over a local pipe this is imperceptible; over
  a long network link it adds latency. A local-echo optimisation remains possible.
- State that is purely about presentation (cursor, selection, viewport, which tab
  is active) stays in the frontend (ADR-0022).
