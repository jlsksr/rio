# ADR-0049: A line-number gutter drawn from the text widget's geometry

- **Status:** Accepted
- **Date:** 2026-08-19
- **Deciders:** jka
- **Decision log:** AGENTS.md D49

## Context

A code editor needs line numbers. The usual Tk approach is a second text widget
beside the editor, which cannot stay aligned when long lines wrap.

## Decision

Each editor group has a line-number gutter, on by default and toggled with View ▸
Line Numbers (persisted).

- The gutter is an unfocusable **canvas**, not a text widget.
- Numbers are painted at the y position the text widget reports for the first
  display row of each logical line (`dlineinfo`), so a wrapped line shows its number
  once, at its top, and the two cannot drift.
- Repaints are triggered by the text widget's scroll command and by resize, coalesced
  into one idle pass.
- The width follows the digit count of the last line, with a minimum of two digits.
- Colours use the `gutter.fg` and `editor.bg` roles. Mouse wheel events over the
  gutter scroll the text.

## Consequences

- Line numbers stay correct under wrapping.
- Painted numbers need a mapped window, so headless tests can check the width and
  labelling logic but not the painted glyphs.
- Clicking a number (ADR-0061) and relative numbers (ADR-0071) were added later on
  the same gutter. Line numbers in the compare panes are not provided.
