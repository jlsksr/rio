# ADR-0115: Hard dependencies are minimal; optional ones must degrade cleanly

- **Status:** Accepted
- **Date:** 2026-09-09
- **Deciders:** jka
- **Decision log:** AGENTS.md D4, D39, D86, D109; project policy

## Context

rio is meant to be small, easy to deploy on Linux, the BSDs and Windows, and durable over
decades. Every required package is something to install on each platform, something that can
be missing on a server, and something that can disappear. Some features, however, are
impossible without an extension (operating-system file drop, ADR-0086).

## Decision

**Hard dependencies are fixed and few:**

- **GUI:** Tcl/Tk and tcllib's `json`.
- **Core:** Tcl, tcllib (`json`, `md5`), and `tcltls` for https. `http` ships with Tcl.
  `tcltls` loads on first use, so a core that never makes an https request runs without it
  (ADR-0109).
- **git** on the path for git features.

**An optional dependency is acceptable only when the feature degrades cleanly:** it is loaded
with `catch {package require …}`, rio behaves exactly as before when it is absent, and
INSTALL.md (and WINDOWS.md where relevant) documents it as optional. `tkdnd` for file drop is
the current example.

Adding a hard dependency requires an explicit decision by the maintainer.

Related choices follow from this policy: no libgit2 (ADR-0007), no Img extension for icons
(ADR-0027), no C extension for Unix sockets (ADR-0030), no bundled CA store (ADR-0109), no
external highlighting library (ADR-0032), and no language besides Tcl in the project
(ADR-0004).

## Consequences

- A GUI-only machine needs only Tk and tcllib; a server needs Tcl, tcllib and tcltls.
- Some features are implemented by hand where a library would be shorter (syntax
  highlighting, the Markdown renderer, a line diff).
- Features that a missing optional package disables must say so in the documentation rather
  than fail at load time.
