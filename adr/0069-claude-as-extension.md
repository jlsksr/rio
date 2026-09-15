# ADR-0069: Claude is an installable provider; echo is the only built-in

- **Status:** Accepted
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D69

## Context

ADR-0066 moved OpenAI out of the tree but kept Claude in-tree as an always-present
provider. The maintainer's intent was that agent integration belongs to rio while
individual LLM providers are extensions. Keeping one provider inside and one outside
blurred that line.

## Decision

Claude installs as a `kind = provider` extension from `extensions/claude/`, exactly
like OpenAI. The core ships only the offline `echo` provider. A real agent, including
on the maintainer's own development core, is installed from a repository and
activated on restart.

`plugins/lib/` stays in the tree: it is the `provider-api` runtime the core loads
before any provider, not a provider.

## Consequences

- Providers track fast-moving vendor APIs outside the core, and every provider goes
  through the same install, version gate, key entry and contract.
- A fresh core offers no hosted model until a provider is installed. The Preferences
  Agent page shows a hint pointing at Extensions… while only echo is present.
