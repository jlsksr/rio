# ADR-0063: Hover tooltips for glyph controls

- **Status:** Accepted
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D63

## Context

Several header controls are bare glyphs (the refresh buttons, the hidden-files
toggle) with no label saying what they do.

## Decision

A small tooltip facility, `tooltip $w $text`, names such controls. A single shared
borderless toplevel appears about 600 ms after the pointer rests on a control, below
it and kept on screen, and hides when the pointer leaves. Calling `tooltip` again
replaces the text, so a control whose meaning changes can relabel itself.

The tooltip uses the classic Windows look (pale yellow, black text, one-pixel dark
border) regardless of theme. It is the one element that deliberately ignores theme
roles: it is momentary, and black on yellow is legible over any theme.

## Consequences

- Any bare-glyph control can be named with one line.
- Every glyph-only control added later is expected to carry a tooltip.
