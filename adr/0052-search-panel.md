# ADR-0052: One search panel: two engines, three scopes

- **Status:** Accepted
- **Date:** 2026-08-19
- **Deciders:** jka
- **Decision log:** AGENTS.md D52

## Context

With both an inline find bar (ADR-0036) and a find-in-files panel (ADR-0051), the
question was whether to merge them into one "all things search" dialog, as
Notepad++ does.

## Decision

The two remain separate surfaces, connected by a handoff. The find bar stays the
quick in-buffer tool. The find-in-files panel becomes a general **Search panel** with
three scopes:

| Scope        | Operation                         | Reads                        |
| ------------ | --------------------------------- | ---------------------------- |
| Project      | `project.search`                  | files on disk                |
| Open docs    | `buffers.search`                  | every open buffer's text     |
| Current doc  | `buffers.search` with `only`      | the focused buffer           |

The buffer scopes read live text, so they include unsaved edits. Both engines share
one line matcher (`rio::doc::grep_lines`). Pressing Ctrl+Shift+F in the find bar
carries its needle and options into the panel and widens the scope to Project. The
panel's default scope is Current doc.

**Replace** works in every scope. Buffer scopes use `buffer.replace_all` and leave
changes unsaved. Project scope uses `project.replace`, after a confirmation, and
routes each file by whether it is open: open files are changed through their buffer
(undoable, unsaved), closed files are rewritten on disk with their encoding and line
endings preserved. Disk is never rewritten under an open buffer.

**Regular expressions** are available on every search and replace operation and on
both surfaces. Patterns are Tcl ARE, matched line by line (`^` and `$` anchor at line
boundaries). Whole word is disabled while regex is on, since a pattern states its own
boundaries. Replacement text may use back-references. An invalid pattern matches
nothing rather than raising an error, so a half-typed pattern shows no hits. Because
regex matches vary in length, each match row carries a `lens` array beside `cols`.

## Consequences

- The quick bar and the panel cannot disagree, because they use the same engine.
- The panel lives in the bottom dock site as an ordinary tool window (ADR-0035).
- `project.replace` must call model functions directly instead of nested dispatch,
  so its events are not duplicated.
