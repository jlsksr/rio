# ADR-0110: The agent refuses https without host-name checks unless allowed

- **Status:** Accepted
- **Date:** 2026-09-15
- **Deciders:** jka
- **Decision log:** AGENTS.md D110

## Context

On tcltls older than 1.8 a certificate's chain is verified but its name is never compared
with the host (ADR-0109). On such a core the agent would accept a certificate a trusted CA
issued for any host as if it belonged to the provider. Repositories already refused this.
The agent had been left alone because refusing breaks hosted providers for users who cannot
upgrade tcltls. The maintainer asked for a setting that defaults to the secure behaviour.

## Decision

- **Refuse by default.** On tcltls older than 1.8, an `https://` agent request is refused
  before any connection is made. The message names both remedies: install tcltls 1.8 or
  newer, or enable Preferences ▸ Agent ▸ "Allow https without host-name checks".
- The option has no effect on a tcltls that checks names. **Plain `http://` is never gated**,
  so local model servers keep working on any tcltls.
- **Agent only.** Repositories get no such option: https repositories are new, nobody depends
  on them, and http remains available.
- **The setting belongs to the core.** The tcltls in question is the core's, shared by every
  frontend attached to it. It is stored in `$XDG_CONFIG_HOME/rio/agent/agent.conf` as
  `tls_unchecked_hostnames = allow`. Only the exact word `allow` allows; a missing file, a
  typo or a malformed file all mean refuse. It is read on every https request, so a hand edit
  takes effect without restart.
- The gate is in the providers' transport. It asks `rio::agent::tls_unchecked_ok` at request
  time if that command exists, and refuses if it does not.
- `agent.tls.set {unchecked}` writes the setting; `agent.status` reports `tls_unchecked`. The
  Preferences checkbox reflects what the core stored and reverts on refusal.
- Providers report the refusal as its own error, not as "Couldn't reach … — check your
  connection".

## Consequences

- Hosted providers on old tcltls stop working until the user upgrades or opts in, with a
  message that explains both.
- No `provider-api` change: providers only match message text, so a new provider on an old
  core never takes the new branch.
- The `agent.status` wire encoder had silently dropped the new field while core tests passed.
  Every result encoder that lists keys by name now has a test comparing it with the operation's
  real result (ADR-0025).
