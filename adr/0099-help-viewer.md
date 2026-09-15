# ADR-0099: rio shows its own manual

- **Status:** Accepted; amended by [ADR-0100](0100-manual-renderer.md)
- **Date:** 2026-09-11
- **Deciders:** jka
- **Decision log:** AGENTS.md D99

## Context

ADR-0091 placed the manual in `docs/` with file names as topic ids and `index.md` as
contents, which is most of what a help viewer needs. The Help menu existed with only
About rio, and F1 was unbound.

## Decision

Help ▸ Contents… (F1) opens a help window: the contents as a rich list on the left
(ADR-0043), the selected topic on the right.

- **The GUI reads `docs/` from its own installation**, not through the core. Help is
  part of the GUI. With a remote core, reading through the core would show the server's
  manual, possibly for a different version, or nothing.
- It is a non-modal, single-instance window, like the Extensions window. Whether help
  should become a dock panel (ADR-0035) is left open until it has been used.
- F1 is the keymap command `help` (ADR-0023), so it can be remapped and the shortcut
  documentation check covers it.
- A missing topic is reported inside the window rather than raised as an error.

The first version showed the Markdown source in the editor font.

## Consequences

- The manual is available offline wherever rio runs.
- Tests check that the code's `docs/` location is the real directory and that the
  topics offered are exactly those listed in `index.md`.
- rio is deployed by cloning its repository, so `docs/` is always present beside the
  code; no separate packaging step is needed.
- ADR-0100 added rendering, links and search.
