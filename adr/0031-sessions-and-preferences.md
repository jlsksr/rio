# ADR-0031: Sessions and preferences, split by owner, out of tree

- **Status:** Accepted
- **Date:** 2026-07-01
- **Deciders:** jka
- **Decision log:** AGENTS.md D31

## Context

Launching rio on a project should bring back how the editor looked and which files
were open. ADR-0021 grouped "recent files, window and pane sizes, open tabs" as
session state and sketched storing it in the project's `.rio/` directory. After
ADR-0030 the core may run on another machine, so who owns each piece of that state
matters.

## Decision

The state is split by owner.

- **Preferences** (theme, wrap, dock layout, pane visibility and similar) are pure
  view state. The GUI owns them and writes `$XDG_CONFIG_HOME/rio/prefs.json`. Each
  setting is saved through the single applier that sets it. A missing or corrupt
  file, or a stored value that no longer exists, falls back to defaults.
- **The workspace** (open files in tab order and the active tab) is per project and
  document-related. The core owns it through `workspace.save` and `workspace.get`,
  storing it under `$XDG_DATA_HOME/rio/sessions/<md5-of-root>.json`.
  `workspace.get` drops paths that no longer exist.

Session state is kept out of the project tree. Window geometry and pane pixel
sizes were deferred at first; dock sizes were added to the layout later
(ADR-0035).

## Consequences

- Resume works over a remote core, because the workspace store lives with the core
  and its files.
- Session files never appear in `git status` and cannot be committed by accident.
- Neither store holds a secret.
- Booting the GUI now writes to XDG directories, so every GUI test must redirect
  XDG to a throwaway directory (`rio-gui/tests/sandbox.tcl`).
- ADR-0072 extended the workspace to the no-project case, ADR-0088 remembered the
  last folder, and ADR-0089 added the unfolded tree shape.
