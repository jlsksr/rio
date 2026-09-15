# ADR-0009: The responsive layout rule is a shared pure function

- **Status:** Accepted, not implemented (the TUI is deferred, [ADR-0112](0112-tui-deferred.md))
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D9

## Context

Both frontends must decide how side panes arrange themselves as the available
width changes. If each frontend encodes the rule itself, the GUI and the TUI will
drift apart.

## Decision

The collapse rule, `(width, panes) → layout`, is a pure function in the core that
both frontends call. Only the rendering differs: Tk geometry managers in the GUI,
Ck geometry managers in the TUI. ADR-0014 defines the tiers the function returns.

## Consequences

- The layout policy exists once and can be tested without a display.
- The function has not been built: the GUI currently arranges its panes through
  the dock-site layout of ADR-0035, and the TUI that would consume the shared rule
  is deferred. The decision stands for when a second frontend exists.
- The Ck spike found that Ck reports resizes through `<Expose>` rather than
  `<Configure>`, and that a re-layout must be guarded by an actual width change to
  avoid a repaint loop. A TUI rendering this policy inherits that rule.
