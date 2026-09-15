# ADR-0016: A plugin is a protocol participant

- **Status:** Accepted, not implemented (the general plugin platform is deferred)
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D16

## Context

rio should be extensible for architectural reasons: a small core with clean
seams ages better. rio is not trying to attract an ecosystem, and supporting
several scripting languages one by one would bloat the core.

## Decision

A plugin attaches to the same protocol as a frontend (ADR-0011). There are two
tiers with the same contribution API, differing only in transport:

- **Out-of-process, any language (primary).** The core spawns the plugin and
  speaks JSONL over its standard streams or a socket. A crashing plugin cannot
  take down the core.
- **In-process Tcl (opt-in).** Loaded as a Tcl package with direct calls, for
  trusted or performance-sensitive extensions.

rio supports one protocol rather than individual languages. Thin per-language
SDKs live outside the core; the core ships a Tcl SDK and one reference SDK.

## Consequences

- Multi-language support follows from the existing boundary at little cost.
- Out-of-process isolation makes sandboxing possible later.
- The general platform (contribution API, manifests, SDKs) waits until real
  consumers exist. The extension kinds rio does ship today (syntax, modes,
  themes, providers) use narrower seams: ADR-0032, ADR-0038, ADR-0024, ADR-0066.
- Chatty contributions such as per-keystroke highlighting may need the in-process
  tier or batching; that threshold is an open question.
