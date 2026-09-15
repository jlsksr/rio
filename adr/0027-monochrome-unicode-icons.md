# ADR-0027: Icons are monochrome Unicode glyphs

- **Status:** Accepted
- **Date:** 2026-06-29
- **Deciders:** jka
- **Decision log:** AGENTS.md D27

## Context

The GUI needs a few iconic affordances: close, refresh, send, expand and collapse,
unsaved marker. The options were raster icons (including the classic Windows
`.ico` set), colour emoji, or text glyphs.

## Decision

Iconic controls use monochrome Unicode symbol glyphs, limited to code points that
common monospace fonts cover (for example `× · → ● ○ ▸ ▾ ⟳ ↑ ↓ ▶`). Where coverage is
doubtful, a plain text label is used instead.

Glyphs cost no assets, take the theme's foreground colour, and scale with the font.
If true pixel icons are ever wanted, they are PNG files through Tk's core `photo`
image type.

## Alternatives considered

- **`.ico` files.** Tk 8.6's `photo` reads PNG and GIF but not `.ico`; reading them
  would need the Img extension, a dependency rio avoids. The classic Windows icon
  set is not freely redistributable, and raster icons do not scale with font size.
- **Colour emoji.** Tk 8.6 does not render colour emoji, and emoji clash with the
  monospace look.

## Consequences

- Icons recolour through the theme with no additional roles.
- Some idioms stay text by choice: the file pane's trailing `/` for directories
  and git's own porcelain status letters.
- A search glyph (`⌕`) has no on-screen home yet.
