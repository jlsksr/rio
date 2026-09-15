# ADR-0062: Hide dotfiles in the files pane by default

- **Status:** Accepted
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D62

## Context

The files pane listed `.git/`, `.gitignore` and other hidden entries, cluttering a
narrow pane. `ls` hides them by default, and Windows Explorer has a "Hidden items"
option.

## Decision

The files pane hides entries whose names start with `.` unless View ▸ Show Hidden
Files is on. The filter is applied when the pane renders; `fs.list` in the core still
returns every entry, because hiding is a presentation choice.

The setting has three controls bound to one variable and one applier: the View menu
item, the Preferences checkbox, and a glyph button in the files pane header. The
header glyph shows the state: `◉` when hidden files are shown, `◌` when they are
hidden. Its tooltip (ADR-0063) changes with it.

## Consequences

- The default matches the Unix convention.
- The setting persists with the other view preferences.
