# ADR-0068: Static help must look different from controls

- **Status:** Accepted
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D68

## Context

In the Repositories dialog, a hint sentence in the normal text colour sat directly
above a borderless listbox whose single repository URL used the same colour. The
selectable, removable entry read as another line of help. The maintainer had
corrected this kind of problem more than once.

## Decision

In every window, explanatory text and interactive elements must be distinguishable
at a glance. Two measures are used together:

1. Help, description and hint text uses a muted secondary role (`gutter.fg`), never
   the `ui.fg` colour used by interactive text.
2. Interactive containers (lists, entries, text areas the user can select from) have
   a visible boundary (`-relief solid -borderwidth 1`), not a borderless widget on the
   window background.

Every new dialog is checked for help text that looks like a control, and controls
that look like help, before it ships.

## Consequences

- Users do not have to guess what is clickable.
- The rule is applied throughout later dialogs: agent prompts (ADR-0070), accepted
  certificates and the certificate review (ADR-0111).
