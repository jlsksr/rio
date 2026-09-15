# ADR-0004: Tcl/Tk for core and GUI, Ck for the TUI

- **Status:** Accepted; the TUI is deferred by [ADR-0112](0112-tui-deferred.md)
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D4

## Context

rio needs to run on Linux (Debian, Alpine), the BSDs and Windows, with a graphical
and a terminal face. The maintainer wanted a from-scratch project in Tcl/Tk, and
the implementation language decides how much of the frontend code the two faces
can share.

## Decision

- The core and the GUI are written in **Tcl/Tk**. Tcl/Tk has real cross-platform
  reach, single-file distribution options (Tclkit, starpacks, `vanillawish`), and a
  strong editing widget.
- The TUI uses **Ck**, a Tk-shaped toolkit that renders to curses with Tk-parallel
  widgets (`text`, `listbox`, `entry`, `frame`, `menu`, `scrollbar`) and the same
  geometry managers. Candidate builds are `vzvca/ck8.6` and `vanillatclsh`.
- rio is Tcl throughout. No other implementation language is used in the
  project, including for scratch scripts or build helpers.

The contributor toolchain is `tcl`, `tk`, `tcllib` (for `json`), `tcl-tls` and
`git`. `rio-dev-deploy.sh` installs it on apt, apk and `pkg_add` systems and can
build Ck from source.

## Alternatives considered

- **Writing a TUI toolkit from scratch.** Rejected: Ck provides Tk-parallel
  widgets and removes the riskiest custom work.
- **Perl/Tk with `Curses::UI`.** Perl has a more mature TUI library, but the same
  dated Tk and a weaker single-binary story. Kept only as a fallback if Ck failed.

## Consequences

- The GUI and a future TUI can share idioms, not only the core.
- Headless Tcl must not load Tk (see ADR-0001).
- The Ck spike (ADR-0112) passed on rendering and layout and found
  cross-terminal keyboard handling to be the real cost; the TUI was then deferred.
