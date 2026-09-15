# ADR-0066: Providers install from repositories, behind a versioned API

- **Status:** Accepted; amended by [ADR-0069](0069-claude-as-extension.md)
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D66

## Context

ADR-0065 hardened the provider contract. The maintainer wanted people to contribute
providers through the same repositories as other extensions, without a second
distribution system. A provider is a different kind of extension from those shipped
so far: it is executable Tcl that loads into the core (which may be remote or
shared), receives the user's API key, and makes network calls with it.

## Decision

`provider` is an installable kind in the repositories of ADR-0039. The in-tree OpenAI
provider was moved to `extensions/openai/` as the first one.

- **Core-side install.** `provider.put`, `provider.list` and `provider.delete` store
  providers under `$XDG_DATA_HOME/rio/providers/<name>/`, on the core's host.
- **Activation on restart.** `provider.put` writes files but does not load them. The
  core loads every installed, supported provider once at start-up. Loading freshly
  fetched code into a long-running, possibly shared core is a larger trust step than a
  deliberate restart; the GUI tells the user.
- **A versioned contract, `provider-api`.** The registration options, the provider
  procedure's arguments and posted messages, and the runtime helpers (`rio::llm::*`,
  `rio::secret::*`) form version 1. A manifest declares the version it targets. The
  core refuses to install a provider needing a newer API, and lists but skips one
  already on disk. `provider.list` reports the maximum supported version so the GUI
  can grey out such rows.
- **Specific consent.** The install dialog states that the code runs in the core
  (possibly on another machine), can receive the key entered for it, and makes network
  calls with it.

## Consequences

- One distribution system serves every extension kind.
- The credential risk is stated at the moment it matters.
- Changes to the shared runtime that providers call require an API version increase
  (it reached 3 by ADR-0106), so a provider never loads against a core lacking what it
  needs.
- ADR-0069 moved Claude out of the tree as well.
