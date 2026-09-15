# ADR-0059: Patching Tk's menu click behaviour

- **Status:** Rejected (shipped, then reverted)
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D59

## Context

Tk's default menus behave inconsistently: clicking a menubar item posts its menu and
highlights the first entry, while sliding the pointer to an adjacent menu posts it
with nothing highlighted. The maintainer asked for consistent behaviour.

## Decision (as shipped)

On X11, replace the `Menu` class's button-release binding and wrap
`tk::MenuFirstEntry`, using a flag so that the first entry is not activated when the
menu is opened with the mouse.

## Why it was reverted

In real use the change produced intermittent misfires: a click that immediately
invoked the first menu item, and clicks that left the menu stuck. Replacing the
shared class binding and interposing on Tk's internal procedures is too tightly
coupled to Tk's grab, post and invoke ordering to be reliable. The code was removed,
together with its test, and menus use stock Tk behaviour. The source contains a note
not to reintroduce it.

## Consequences

- The cosmetic first-entry difference is accepted.
- Standing rule: rio does not patch Tk's menu machinery. If this polish is wanted
  again it needs a mechanism that neither rebinds `Menu <ButtonRelease>` nor overrides
  `MenuFirstEntry` or `MenuInvoke`.
- The same rule decided ADR-0064 and ADR-0092: menus that could overflow the screen
  are bounded by design rather than fixed inside Tk.
