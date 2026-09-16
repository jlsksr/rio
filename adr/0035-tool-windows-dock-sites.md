# ADR-0035: Tool windows live in dock sites, not in the document tabs

- **Status:** Accepted
- **Date:** 2026-07-12
- **Deciders:** jka
- **Decision log:** AGENTS.md D35

## Context

A proposal: make the agent chat an ordinary tab in the rightmost editor group, so
users place it with the same drag, split and reorder gestures as documents, and let
future extension panels use the same seam. The instinct (one universal placement
mechanism) was sound. Two structural problems and one design principle stood
against the literal form:

- A **buffer** is a precise core concept (ADR-0003): a document with a path,
  encoding and undo history. The chat has none of these. Treating it as a buffer
  means faking one through close, save and activation, or teaching the core about a
  non-file buffer.
- An **editor group** is built around one text widget per tab (ADR-0033). Hosting
  other view types means turning it into a generic panel container, a large
  refactor of the most delicate GUI code.
- Windows 2000-era productivity software drew a clear line between documents
  (centre, tabbed) and tool windows (docked, with their own tabs). That separation
  is part of the clarity rio aims for.

## Decision

Documents and tool windows remain separate categories.

- Documents stay in the editor groups.
- Tool windows (files, git, agent chat, search results, and later extension panels)
  are hosted by a **dock-site system**: three sites (left, right, bottom), each a
  tabbed container. Any panel can move to any site.

The build settled these points:

- A panel is declared as data in a registry (`{title, site, body, refresh}`), in
  the style of the highlighter and mode registries. The host owns the chrome; a
  panel supplies a body and a refresh hook.
- One persisted `layout` object is the source of truth: for each site its panels in
  order, which are hidden, which is active, and its size. Packing is derived from
  it. Older flat preference keys are migrated into it.
- The find bar and the compare view are not panels: the find bar belongs to the
  focused document, and the compare view replaces the document area.
- A tab strip contains tabs only. A panel's controls live in its body: thin
  captions at the top for browsing panes (files, git) and input areas at the bottom
  for composing panes (chat, search). Folding the search controls into the tab
  strip was tried and rejected; the controls mixed visually with the tabs and
  competed for width, and the chat composer could never fit there.
- Panels move with a right-click "Move to" menu and by dragging a tab to another
  site.
- View menu pane items control whether a panel has a tab at all; hiding a site's
  last panel collapses the site. No arrangement may leave a panel with no menu path
  back.
- Dock sizes are chosen by the user with sashes and never change because of their
  content.
- A new user sees only the Files panel; Git, Agent and Search start hidden.

## Consequences

- One placement mechanism serves every tool window, and a plugin panel will be a
  later caller of the same registry rather than a new design.
- The editor group invariants and the buffer model are untouched.
- Layout is queryable state, so the placement logic is testable without a mapped
  window. The feel of dragging still needs a live check.
- Plugin-contributed panels wait for the plugin interface (ADR-0018).
- The direction was settled on the date above; the dock sites themselves were built on
  2026-08-20.
