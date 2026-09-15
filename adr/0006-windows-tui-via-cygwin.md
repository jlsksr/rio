# ADR-0006: Windows TUI through Cygwin, PDCurses as fallback

- **Status:** Accepted, not implemented (the TUI is deferred, [ADR-0112](0112-tui-deferred.md))
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D6

## Context

The GUI runs natively on Windows through Tk. A terminal frontend on Windows has
two possible curses implementations: real ncurses under Cygwin, or PDCurses in a
native build such as `vanillatclsh-win32`.

## Decision

The primary Windows TUI path is **Cygwin**, which uses real ncurses and therefore
the same code path as Linux and the BSDs. Native **PDCurses** remains a fallback.

| Platform         | GUI (Tk)  | TUI (Ck)                   |
| ---------------- | --------- | -------------------------- |
| Linux / BSD      | native Tk | native ncurses             |
| Windows native   | native Tk | PDCurses (BMP-only)        |
| Windows + Cygwin | not used  | ncurses, same as Linux     |

## Consequences

- The Windows TUI shares the tested Unix code path instead of a less-proven one.
- The PDCurses fallback renders only the Basic Multilingual Plane. That is
  sufficient for a code editor; rio's iconography avoids astral code points
  (ADR-0027).
- Cygwin keyboard behaviour was not tested in the Ck spike and remains open.
