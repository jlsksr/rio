# ADR-0056: The editor font is a user override on the theme font

- **Status:** Accepted
- **Date:** 2026-09-03
- **Deciders:** jka
- **Decision log:** AGENTS.md D56

## Context

The editor font is the named font `RioEditorFont`, supplied by the theme
(ADR-0024). Users need to choose their own family and size, and to zoom quickly while
reading a log file, without editing a theme file.

## Decision

The theme remains the source of the default. The GUI adds a thin user override,
stored as two preferences: `font_family` (empty means follow the theme) and
`font_size` (0 means follow the theme). One procedure, `apply_editor_font`, overlays
them onto the theme values, reconfigures the named font, and repaints chrome whose
geometry depends on character width (gutter, wrap indentation). A theme switch keeps
the user's override.

Zoom steps set an absolute size, clamped to 5–72. Ctrl+0 or "Use Theme Font" clears
the override.

The zoom inputs (Ctrl+wheel, Ctrl+Plus, Ctrl+Minus, Ctrl+0) are bound directly on the
editor and gutter, outside the keymap of ADR-0023, as fixed accelerators. Both the X11
and the Windows/macOS wheel events are handled.

## Consequences

- Font choice survives theme changes and restarts.
- The override applies to the document view only; UI and chat fonts stay with the
  theme.
- Zoom keys cannot be remapped.
