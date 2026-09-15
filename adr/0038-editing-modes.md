# ADR-0038: Editing modes as a bind-tag layer

- **Status:** Accepted; amended by [ADR-0041](0041-unbundled-editing-modes.md)
- **Date:** 2026-07-12
- **Deciders:** jka
- **Decision log:** AGENTS.md D38

## Context

The text area's keyboard behaviour was whatever Tk's `Text` class bindings happened
to provide: on X11 a partial emacs flavour, no Select All, and a reported bug where
Ctrl+V appeared to break scrolling. Reading Tk's own sources showed that on X11
Ctrl+V is bound to `<<Paste>>` and page scrolling on it exists only on macOS, so the
key was silently pasting at the caret. The keys had never been a decision.

## Decision

rio has **editing modes**, selectable in Settings ▸ Editing Mode and persisted as a
preference. The default is **windows** (Ctrl+A select all, Ctrl+C/X/V clipboard with
paste replacing the selection, Ctrl+Backspace/Delete word deletion, Tab indenting a
selected block as one undo step). **emacs** and **vi** (modal, with counts, motions and
operators) are also provided.

The mechanism is one shared bind tag, `RioMode`, placed between the widget and the
`Text` class in every editor's bind tags:

    <widget>   RioMode   Text   .   all

This fixes precedence by construction: application chords bound on the widget
(ADR-0023) always win; mode bindings that `break` override Tk's defaults; anything a
mode does not bind falls through to Tk. Switching modes detaches the old mode and
clears the tag, so no binding can leak, and a split created later is covered
automatically.

A mode is a self-registering module (`rio::modes::register name label attach
detach`), loaded like highlighters: shipped modules first, then drop-ins from
`$XDG_CONFIG_HOME/rio/modes/`, later registration winning, broken modules skipped.
Mode modules are frontend code; only the registry is toolkit-free. Mode state is
per editor group. Operators edit through the group's proxy so an operation such as
`dd` is one core edit and one undo step. The Edit menu's clipboard items call the
same procedures the windows mode binds.

## Alternatives considered

Waiting for the plugin API of ADR-0017. Its declarative UI model (ADR-0018) is
unsuited to behaviour that runs on every keystroke, and the highlighter loader was
already proven.

## Consequences

- Keyboard feel is a user choice, and the Ctrl+V defect is fixed.
- Save, find and undo chords work in every mode.
- The core never learns which mode is active.
- vi motions use Tk index arithmetic only, never `expr` (see ADR-0012).
- This closed the open question of the default keymap: the windows mode is the
  default feel, and modal editing is a first-class mode.
- Making emacs and vi complete is open-ended work, which led to ADR-0041.
