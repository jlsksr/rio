# ADR-0117: A fact kept in two places must have a guard

- **Status:** Accepted
- **Date:** 2026-09-10
- **Deciders:** jka
- **Decision log:** AGENTS.md §7, "The derived-facts register"

## Context

Some facts must be stated twice: the code is the source of truth, and a document repeats the
fact for readers who will not open the source. That copy decays without anything failing. The
keyboard shortcut table had lost seven commands by the time ADR-0091 was written, and the
table of configuration files predated the agent directory and the provider store.

The existing rule, "keep the documents in sync", failed because it relied on whoever edited
the code knowing that a copy existed. A periodic "revisit these" checklist would fail the same
way.

## Decision

AGENTS.md keeps a **register of facts with two homes**. Each row names the source of truth,
the copy, and the **guard** that fails when they diverge. A row without a guard is a backlog
item, and the remedy is to write the guard, not to schedule a review.

Current rows include: the keymap and `docs/keyboard.md`; the `docs/` files and `index.md`;
the keys `prefs_save` writes and `docs/preferences.md`; the configuration and data paths and
their documentation; every menu named in the documents and the real menubar; the editor
context menu and `docs/editor.md`; the system CA locations and INSTALL.md. Two rows have no
guard and are listed as such: README's feature summary, which is prose, and the manual copy of
`extensions/` into the test repository.

Rules for guards:

- **Assert against behaviour, not source text.** The preferences guard runs `prefs_save` and
  reads the file it wrote.
- **Check both directions.** A document that names a setting, path or menu that does not exist
  is the same drift, and it is the direction reviewers miss.
- Where a check needs a marker, adopt a documentation convention: menu paths are written in
  emphasis so a renamed item fails, and in the editor context-menu section bold marks a menu
  entry.
- Design logs (AGENTS.md, ROADMAP.md, CAVEATS.md, RELEASING.md, and these records) are exempt,
  because they deliberately name retired and future interfaces.

## Consequences

- Drift in guarded facts is caught by the test suite at the commit that introduces it.
- Documentation authors follow a few conventions the guards depend on.
- Facts that are only prose remain unguarded and must be reread when the underlying status
  changes.
