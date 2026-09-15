# ADR-0091: The user manual lives in the source tree

- **Status:** Accepted
- **Date:** 2026-09-10
- **Deciders:** jka
- **Decision log:** AGENTS.md D91

## Context

rio had documents for contributors, deployment and rough edges, but nothing that told a
user how to use the editor. The usage material that existed had drifted into
INSTALL.md, and its shortcut table was missing seven commands. The earlier plan was a
separate wiki repository.

## Decision

The user manual is Markdown in `docs/` in the source tree, written so rio can later
display it as built-in help, in the manner of WinHelp: a contents page, topic pages,
links between them, F1.

- One topic per file. **The file name is the topic id**; it is stable and not renamed
  casually, because links and future context help depend on it.
- `index.md` is the contents. Each page's first heading is its title and matches its
  contents entry.
- Links between topics are relative.
- A restricted Markdown subset: headings, paragraphs, lists, inline code, fenced
  blocks, links, bold and italic, simple pipe tables, block quotes. No HTML, images,
  footnotes, nested tables or task lists. Each construct maps onto a Tk text tag or an
  indent.
- Second person, present tense, the rule and a one-line reason, no decision numbers.
- Each fact has one home: the manual covers use, INSTALL.md installation and
  deployment, CAVEATS.md rough edges. Pages link rather than repeat.
- A stub page is allowed if it states its scope and points to where the facts are today.

## Alternatives considered

A separate wiki repository. In-tree documentation ships with rio (a help viewer needs
local files), versions with the code so a feature and its page land in one commit, and
is reviewed in the same diff.

## Consequences

- Help can be built on top of files that already exist (ADR-0099, ADR-0100).
- Facts copied from code into the manual (the shortcut table, preference keys, file
  locations) need guards against drift (ADR-0117).
- Maintenance of the manual's prose is delegated to a separate documentation workflow
  described in DOCS.md.
