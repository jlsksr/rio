# ADR-0036: Find and replace: the engine in the core, a bar in the GUI

- **Status:** Accepted
- **Date:** 2026-07-12
- **Deciders:** jka
- **Decision log:** AGENTS.md D36

## Context

rio had no Find at all, below the baseline of any 1990s text editor. The first
proposal used Tk's `text search` on the GUI's widget. That searches the view's
mirror of a document the core owns, would have to be reimplemented by every other
frontend, and would not extend to searching a project that exists only on a remote
core.

## Decision

Matching runs in the core, as stateless operations beside the document model:

- `buffer.find {needle, ?from?, ?nocase?, ?backwards?, ?wholeword?, ?regex?}`
  returns the next match from a position the caller supplies, wrapping around.
  No find state is kept in the core, because the caret belongs to the frontend
  (ADR-0022).
- `buffer.matches {…}` returns every match, for the count and highlighting.
- `buffer.replace_all {needle, text, …}` replaces every match as one recorded edit:
  one undo step and one `buffer.changed`.
- A single Replace needs no operation: it is a found range plus `buffer.replace`.

The GUI has a find bar rather than a modal dialog: a Find row, and a Replace row
added with Ctrl+H, acting on the focused editor group. Matches are painted as the
needle is typed (capped at 1000 painted ranges; the count stays exact). Replace
follows the two-step convention: the first press selects a match, the next replaces
it, so a replacement is always visible before it happens. An open bar recounts
after any change to the buffer. The keys are keymap commands, and the highlight
colour is the `editor.findmatch` theme role.

## Consequences

- Every frontend shares one engine, and project-wide search became an extension of
  it (ADR-0051, ADR-0052) instead of a second architecture.
- A Find Next costs one round trip, the same as a keystroke.
- The find bar became the reference for how later panes should feel: appearing only
  when needed, few controls, and immediate.
- Whole word and regular expressions were added later on the same operations
  (ADR-0051, ADR-0052).
