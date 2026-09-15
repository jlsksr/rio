# ADR-0041: The core ships one editing mode; emacs and vi are extensions

- **Status:** Accepted
- **Date:** 2026-08-03
- **Deciders:** jka
- **Decision log:** AGENTS.md D41

## Context

ADR-0038 shipped three editing modes in the source tree. Making emacs and vi
complete (ex commands, registers, repeat, macros, marks, a kill ring) is
open-ended work that would keep growing inside rio's own tree.

## Decision

rio ships only the **windows** mode. **emacs** and **vi** move to installable
extensions of kind `mode`, served from a repository (ADR-0039), where they can be
versioned and developed on their own schedule.

The project keeps its own extensions in `extensions/`, laid out as a complete
repository (`rio-repository.conf`, `index`, one directory per extension with its
manifest and payload). Copied to any web directory, it is a working repository, and
it serves as the reference example for the format documented in CONTRIBUTING.md.

## Consequences

- No new mechanism was needed: mode extensions install into the drop-in directory
  the mode loader already reads.
- A user whose saved mode is no longer installed falls back to the windows mode.
- Mode tests install the extensions through the same drop-in path a user's install
  uses, rather than loading shipped files.
- Changes to `extensions/` must be copied to the maintainer's test repository by
  hand; there is no automated mirror (ADR-0117 lists it as unguarded).
- The same move was later made for LLM providers (ADR-0066, ADR-0069).
