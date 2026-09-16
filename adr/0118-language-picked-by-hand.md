# ADR-0118: A buffer's language can be picked by hand

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** jka
- **Decision log:** AGENTS.md D112

## Context

A buffer's highlighter came from its file name alone (ADR-0032, ADR-0046): the exact
file name, then the extension, then the name with its last suffix removed. rio never
looks at the content, so there is no shebang or modeline detection. Two cases had no
remedy. Code pasted into an untitled buffer was always plain text, and a file whose name
suggests the wrong language was always highlighted wrongly.

The list of languages is not fixed. Every installed syntax extension (ADR-0039) adds one,
so any control that lists them is data-driven and unbounded. ADR-0092 retired the last
menu of that shape.

## Decision

**View ▸ Language…** opens the shared bounded picker (ADR-0092) next to Theme…. Its rows
are *Auto-detect*, labelled with what the file name would give, then *Plain Text*, then
every language the registry knows, shipped or installed. The list is built when the
picker opens, and the picker starts on the buffer's current choice.

The choice belongs to the buffer, not to the editor group or the file type:

- It is GUI view state, held with the buffer like its modified flag (ADR-0022). The core
  is not involved, and the choice follows the buffer when it moves to another group.
- It has three forms: detect by file name (the default), no highlighting, or a named
  language.
- It persists through Save As and renames until the user picks Auto-detect again. A
  hand-picked language is a statement about the content, and a new name does not
  withdraw it.
- It is not saved in the session. A session restores file paths only and does not
  restore untitled buffers at all, so after a restart detection by name applies again.
- If the named language disappears, for example because its syntax extension was
  removed, the buffer falls back to detection by name without an error.

A buffer is re-highlighted whenever its path changes, whether by Save As or a rename,
so an untitled buffer saved as `foo.tcl` is highlighted as Tcl at once.

## Alternatives considered

**A View ▸ Language submenu**, which was the original proposal. The cascade would grow
with every installed syntax extension, and over-tall Tk menus misbehave on X11. ADR-0092
replaced the theme cascade with a picker for exactly that reason.

**Detecting the language from content**, such as a shebang line. It would help
extension-less scripts, but it is a separate question from a manual override and was
left out of this step. A hand pick covers pasted code, which content sniffing would
only guess at.

**Remembering the choice across restarts.** Sessions store paths, not per-buffer view
state, and the main case (an untitled buffer) is not restored anyway. Detecting by name
again after a restart is the least surprising behaviour.

## Consequences

- Pasted code and misnamed files can be highlighted correctly without renaming anything.
- The syntax registry has to answer two questions besides "which scanner fits this
  path": the names of all registered languages, and the scanner for a given name.
- A hand pick outlives a rename, so a user who renames `notes.txt` to `notes.tcl` after
  picking Plain Text keeps plain text until they choose Auto-detect.
- A choice lasts only for the running session. If users want it kept, a per-file
  override would need a home in the session data.
- Shebang detection remains open, as ADR-0046 already noted.
