# ADR-0021: Plain-text configuration in XDG locations, never executed

- **Status:** Accepted; session storage amended by [ADR-0031](0031-sessions-and-preferences.md)
- **Date:** 2026-06-25
- **Deciders:** jka
- **Decision log:** AGENTS.md D21

## Context

Tcl makes it tempting to use a Tcl script as a configuration file. That runs
arbitrary code at start-up and turns a typo into a start-up failure. rio also
holds different kinds of state (human-written settings, machine-written session
data, secrets) that have different owners and different handling needs.

## Decision

State is kept in three separate kinds of file.

- **User settings** are a flat `key = value` file with `[section]` headers and
  `#` comments, UTF-8. They are data. rio parses them and never `source`s them.
  The parser is `rio::conf`, shared with themes, manifests and other conf files.
- **Session and workspace state** is written by rio as JSON and is not meant for
  hand editing.
- **Secrets** (API keys) are kept apart from both, in a store under the data
  directory with the directory at 0700 and each file at 0600
  (`rio-core/secret.tcl`).

Locations follow the XDG Base Directory specification:
`$XDG_CONFIG_HOME/rio/` (default `~/.config/rio/`) for configuration and
`$XDG_DATA_HOME/rio/` (default `~/.local/share/rio/`) for data. A project may carry
its own settings in `.rio/` at its root.

## Consequences

- Configuration is diff-friendly, readable, and cannot execute code.
- A broken configuration file degrades to defaults rather than stopping rio; this
  rule is applied to every later file rio reads (key maps, preferences,
  allow-lists, certificate exceptions).
- ADR-0031 moved personal session state out of the project tree, so `.rio/` holds
  only project-level, committable material (prompts, allow-lists, plans).
- The intended Windows locations (`%APPDATA%`, `%LOCALAPPDATA%`) were never
  implemented. On Windows 11 Tcl derives `HOME` from `HOMEDRIVE` and `HOMEPATH`, so
  the XDG fallback resolves under `%USERPROFILE%` and works. The cost is that the
  0600/0700 permissions are a no-op on NTFS; the key file inherits the profile's
  permissions.
