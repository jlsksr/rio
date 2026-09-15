# ADR-0040: Column editing as a GUI-only vertical cursor

- **Status:** Accepted
- **Date:** 2026-07-23
- **Deciders:** jka
- **Decision log:** AGENTS.md D40

## Context

Notepad++'s column mode lets the user drag a vertical caret across several lines and
type on all of them at once, or select a rectangle and overwrite it. rio's users
asked for the same.

## Decision

rio provides column editing, off by default and enabled by a setting.

- **Gesture:** Ctrl+Shift+drag. Notepad++ uses Alt+drag, but most Linux window
  managers take Alt+drag to move windows.
- **Scope:** bound in the windows editing mode only; the setting is greyed out in
  other modes.
- **Mechanism:** no core change. A column operation reads the affected line span,
  applies the per-line edit (padding short lines with spaces), and sends a single
  `buffer.replace`. A 40-line column edit is one undo step and one change event, the
  same technique used by Replace All and block indent.
- **Rendering:** a rectangular selection uses a tag in the selection colour; a
  zero-width column caret is drawn as thin blinking bars, one per line, with the
  native caret hidden while the column is active.

## Consequences

- The core and the protocol learn nothing new.
- Columns are character columns, so a tab inside the band can look misaligned.
- Rectangular clipboard operations, keyboard-built columns and arbitrary multiple
  carets are out of scope; multiple carets would generalise the same single-replace
  approach.
