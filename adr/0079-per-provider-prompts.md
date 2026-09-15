# ADR-0079: A per-provider prompt layer

- **Status:** Accepted
- **Date:** 2026-09-08
- **Deciders:** jka
- **Decision log:** AGENTS.md D79

## Context

With two providers available, users wanted instructions scoped to one model, such as
formatting preferences for Claude or house rules for a local model, in addition to the
global and project layers of ADR-0070. The prompt must remain a core concern.

## Decision

A fourth layer, `providers/<name>.md` in the XDG agent directory, is included only
while that provider is active. Composition order is **base, system, provider,
project**: project instructions stay last as the most specific.

- The provider contract does not change. `compose` takes the active provider's name
  and folds the file into the single system string the provider already receives. A
  provider never knows the layer exists.
- `echo` has no provider layer. A missing file or unknown name adds nothing.
- The file name is restricted to `[A-Za-z0-9_-]+`, the shape of a registered provider
  name, so it cannot point outside the directory.
- `agent.prompt.edit` accepts `which = provider` with a `name` validated against the
  registry.
- The Agent Prompts… dialog gains a provider chooser row. The Preferences Agent page
  gains an Agent Prompts… button and a hint when only echo is installed.

## Consequences

- Instructions can target one model without affecting others, with no provider changes.
- The per-provider layer is user-wide. A project-and-provider layer is not built.
- The allow-list of ADR-0084 was given the same three scopes for consistency.
