# ADR-0023: Keybindings are data

- **Status:** Accepted
- **Date:** 2026-06-25
- **Deciders:** jka
- **Decision log:** AGENTS.md D23

## Context

Hard-coded key bindings drift between the places that state them (the binding
itself and the menu's accelerator label), cannot be remapped without editing code,
and would have to be written twice for a GUI and a TUI.

## Decision

Keys are mapped through a table from key chord to named command, loaded as data
and overridable by the user. Frontends never tie behaviour directly to a key. The
GUI and the TUI share one logical command set; the chords a TUI can offer are
bounded by what terminals deliver.

In the GUI:

- `::keymap_default` is the single table, `command → {chord action label}`.
  Widget bindings and every menu accelerator are derived from it, so a remap moves
  the key and its menu label together.
- Users override chords in `$XDG_CONFIG_HOME/rio/keys.json` (`{"command":
  "chord"}`, with `""` to unbind). A missing or corrupt file, an unknown command or
  an invalid chord is skipped and reported once after start-up.
- Changes apply live: bindings are cleared and re-applied and accelerators
  re-derived. Settings ▸ Keyboard Shortcuts… records chords by pressing them,
  checks conflicts, and saves only the differences from the defaults.

## Consequences

- Remapping is a configuration change, and adding a command is one table entry.
- The keyboard-shortcut documentation can be checked against the table
  (ADR-0117).
- A few accelerators are fixed and not remappable (zoom, `Esc` in the compare
  view), by decision in ADR-0056.
- The editing feel of the text area itself (as opposed to application commands) is
  handled by editing modes (ADR-0038). Application chords always take precedence
  over a mode's keys.
