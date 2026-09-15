# ADR-0019: Plugin manifest and permissions; no marketplace platform

- **Status:** Accepted; distribution amended by [ADR-0039](0039-extension-repositories.md)
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D19

## Context

Extensibility designed in from the beginning raises two questions early: how a
plugin declares what it is and what it may do, and how plugins are distributed.
A VS Code-style marketplace brings trust, supply-chain and signing concerns, and
a platform someone has to operate.

## Decision

- Each plugin ships a **manifest**: identity, entry command and language, declared
  contributions, and declared permissions (filesystem scope, network,
  command execution). The user consents to permissions on install.
- A marketplace or in-app store is not ruled out, but rio will not build or
  operate a marketplace service. When distribution is needed it should be
  self-hostable, need no special infrastructure, and make the default store a
  single configuration entry that can point anywhere.
- The initial leaning was git as the distribution medium, with a Forgejo instance
  as the default catalogue.

## Consequences

- Manifests and permissions are specified before any installer exists, so an
  installer does not have to be retrofitted onto them.
- ADR-0039 realised distribution as plain-HTTP directory repositories in the
  apt-sources style and dropped git as the transport; a Forgejo raw-file URL still
  qualifies as such a directory. The self-hosted, no-platform intent is unchanged.
- Parsers ignore unknown manifest keys, so the format can grow permission keys
  when plugin-kind extensions arrive. That forward-compatibility rule was later
  applied to the protocol itself (ADR-0055).
