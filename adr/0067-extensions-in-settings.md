# ADR-0067: The Extensions window moves to the Settings menu

- **Status:** Accepted
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D67

## Context

ADR-0039 placed Extensions… in the View menu, expecting the window to become a dock
panel. It is a management window, and its View neighbours were pane toggles and
display preferences.

## Decision

Extensions… moves to the Settings menu, directly below Preferences…. The two form
the pair of "customise rio" windows: Preferences for built-in settings, Extensions for
installing the providers, modes, themes and highlighters those settings choose from.
The Preferences window carries its own Extensions… button, so the pairing holds from
either entry point.

## Consequences

- The View menu is shorter, which serves ADR-0064.
- Tests assert the item's location so it cannot drift back.
