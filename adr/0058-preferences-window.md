# ADR-0058: A Preferences window that owns no state

- **Status:** Accepted; amended by [ADR-0085](0085-agent-config-in-preferences.md), [ADR-0092](0092-theme-picker.md)
- **Date:** 2026-09-03
- **Deciders:** jka
- **Decision log:** AGENTS.md D58

## Context

Settings were accumulating in the top-level menus, including a view preference
placed in the Tabs menu. As settings multiply, users need one place to find them,
without a second copy of each setting that could drift from the first.

## Decision

A non-modal **Preferences** window (Settings ▸ Preferences…) with a category list on
the left and one page per category.

- **It owns no state.** Each control binds the same global variable as its menu
  counterpart and calls the same applier, which already persists the setting. Tk
  keeps a menu checkbutton and a window checkbox in step through the shared variable,
  with no synchronisation code.
- **Changes apply immediately.** There is no OK or Cancel, because every view setting
  in rio already applies live. The keyboard shortcut editor keeps its working copy and
  Save button, because a half-recorded chord must not apply; the Preferences window
  links to it rather than reimplementing it.
- **Only settings.** Commands such as Zoom, Split or Compare stay in menus.
- Lists that grow with installed extensions (themes, editing modes) are built from the
  core and the mode registry.
- A `preferences` keymap command ships with no chord.

## Consequences

- Adding a setting to Preferences is one control bound to an existing variable.
- ADR-0085 later made Preferences the only home for heavier agent configuration,
  reversing the "second door" arrangement for that group.
- The theme dropdown was replaced by a button that opens a bounded picker (ADR-0092).
