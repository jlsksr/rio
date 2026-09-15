# ADR-0092: The theme menu becomes a bounded picker

- **Status:** Accepted
- **Date:** 2026-09-10
- **Deciders:** jka
- **Decision log:** AGENTS.md D92

## Context

After ADR-0074 one unbounded, data-driven menu remained: the Theme cascade, which grows
with every theme installed from a repository. The Preferences window's theme dropdown
(ADR-0058) was a second menu over the same list. An over-tall Tk menu can unpost on
hover on X11, and rio does not patch Tk's menus (ADR-0059).

## Decision

Both are replaced with the bounded picker of ADR-0074, generalised as
`pick_dialog {title rows ?initial?}`: rows are `{payload label}`, the result is the
chosen payload or empty. The dialog sizes itself to its content within limits (6–16
rows, 28–72 columns) and preselects `initial`, the current choice.

- View ▸ Theme… is a command that opens the picker.
- Preferences ▸ View shows the current theme on a button labelled with the theme name
  and an ellipsis, which opens the same picker.
- The list is built when the dialog opens (`theme_pick_rows`), so installs and removals
  need no menu refresh.

## Alternatives considered

A picker with a colour swatch or live preview per row. Drawing each row in its theme's
colours needs one `theme.get` per theme on every opening, which is many round trips over
a possibly remote channel for a rarely used control. It would also need a second dialog
widget, since only a text widget can show several colours in one row. It remains a
roadmap candidate.

## Consequences

- No menu in rio is both data-driven and unbounded.
- One dialog serves tab switching, tab comparison and theme choice.
- The X11 menu behaviour stays documented in CAVEATS.md as the reason menus remain
  grouped.
