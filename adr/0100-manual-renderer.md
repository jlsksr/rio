# ADR-0100: The manual is rendered, with working links and search

- **Status:** Accepted
- **Date:** 2026-09-11
- **Deciders:** jka
- **Decision log:** AGENTS.md D100

## Context

ADR-0099 displayed Markdown source. The densest manual pages are mostly tables, and the
contents page is almost entirely links, which could not be followed. rio's manual read
worse inside rio than in a text editor.

## Decision

**Parsing and painting are separate.** `help_blocks` turns a page into block descriptors
(`heading`, `para`, `item`, `code`, `table`, `quote`, `rule`) with no widget involved;
`help_paint` draws them. The parser is a pure function that tests call with a string.

**Rendering rules:**

- Prose is re-wrapped to the window width; the source's hand wrapping is discarded.
  Code blocks and tables do not wrap and scroll horizontally.
- Tables use the fixed-pitch font, with column widths measured on the text as displayed
  (markup removed), and bold cells use the monospace bold so columns stay aligned. The
  alignment row is dropped.
- Links are per-link tags; a click resolves the tag under the pointer. `topic.md`,
  `topic.md#heading` and `#heading` all go through one navigation procedure. Anchors
  are GitHub-style slugs derived from heading text. Back and Forward are provided.
- Links to rio's other documents (`../README.md`) are followed. Paths that are absolute
  or climb out of rio's directory are refused.

**Search.** A Find box above the contents turns the list into the sections that mention
the text, each with a hit count. Choosing one opens the page at that heading with every
occurrence highlighted in the find colour. Matching is line by line in the GUI, on text
with markup removed.

## Alternatives considered

Searching through the core's project search, as ADR-0091 anticipated. Rejected for the
same reason as ADR-0099: over a remote core it would search the server's files. The
manual is about 50 KB, so reading it on each keystroke needs no index.

## Consequences

- The manual renders legibly and its cross-references work.
- The same renderer displays agent plans (ADR-0101).
- A documentation check verifies that every `#anchor` in the manual names a real heading,
  using the viewer's own slug function, so renaming a heading cannot silently break links.
