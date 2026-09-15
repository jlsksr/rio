# ADR-0043: A shared rich-list component; git flags in the files pane

- **Status:** Accepted
- **Date:** 2026-08-06
- **Deciders:** jka
- **Decision log:** AGENTS.md D43

## Context

After ADR-0042 the git pane still used a listbox and looked different from the files
pane. Users also wanted to see git status (modified, untracked) next to files in the
tree.

## Decision

- The rich list becomes a reusable `rl_*` component keyed by body widget. Each row
  carries a `selectable` flag and an opaque payload the owning pane interprets.
  Panes pass callbacks for selection and activation (and later context menus). One
  row is selected at a time, and the text widget's own text selection is suppressed
  inside the list.
- The git pane becomes an instance of it: each change row shows the two porcelain
  status characters, coloured by kind, then the path.
- The files pane shows a two-character git status column: a file's status letter,
  or a `·` on a directory that contains changes. Colours reuse the diff and accent
  roles.
- Without a file watcher, the panes refresh when rio knows the tree changed: when a
  folder is opened and when a file is saved.

## Consequences

- Both panes share one implementation of look and navigation, while their meaning
  stays in small pane-specific procedures.
- The component was reused for search results (ADR-0051) and the manual's contents
  (ADR-0099).
- Changes made outside rio still needed a manual refresh until ADR-0047.
- Git status in the tree is read-only information; acting on it came with ADR-0044.
