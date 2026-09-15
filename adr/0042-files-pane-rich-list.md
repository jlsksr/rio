# ADR-0042: The files pane is a rich list drawn on a text widget

- **Status:** Accepted; amended by [ADR-0043](0043-shared-rich-list-and-git-flags.md), [ADR-0087](0087-files-tree.md)
- **Date:** 2026-08-06
- **Deciders:** jka
- **Decision log:** AGENTS.md D42

## Context

The files pane was a Tk `listbox`: text only, one colour, one selection bar,
essentially the output of `ls`. A Windows 2000-style navigator needs per-row icons, a
hover band and a full-width selection band, none of which a listbox can draw.

## Decision

The pane body is a read-only `text` widget used as a list canvas: one line per
entry, a monochrome glyph icon followed by the name, and full-width hover and
selection bands implemented as tags that extend through the newline. Colours come
from existing theme roles, with the hover shade derived by blending towards the
selection colour.

This text widget is GUI-local chrome, not a view of a core buffer. It is disabled,
never proxied and never editable. A text widget is used only because it is the best
stock Tk surface for icons, bands, scrolling and keyboard navigation; a canvas would
need all of that computed by hand.

## Consequences

- The pane gains the look and feel the UI principle asks for, with no new theme
  roles.
- rio does not move towards "everything is a buffer". Core-backed read-only view
  buffers remain a separate, untaken option.
- The component was generalised for the git pane in ADR-0043, and the flat
  navigator became a tree in ADR-0087.
