# ADR-0020: Agent orchestration in the core, providers and tools outside

- **Status:** Accepted
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D20

## Context

Should the agent be an extension? VS Code places agent orchestration in
extensions. rio's agent reads files, proposes writes and later runs commands, so
where the tool-executing loop lives decides where the security boundary is.

## Decision

The agent is split along a line of security and volatility.

- **In the core (durable, security-critical):** the orchestration loop
  (conversation state, tool dispatch), the review of proposed changes, and the
  guardrails around tool execution. Every tool call goes through one permission
  model, and the user reviews proposals the same way whichever provider is in use.
- **Outside the core (volatile):** concrete providers (ADR-0008) and additional
  tools beyond the built-in ones.

The provider interface and the tool interface are candidates for alignment with
the Model Context Protocol (MCP) rather than a bespoke contract.

## Alternatives considered

Orchestration in an extension, as in VS Code. Rejected because the security
boundary and cross-provider consistency would then depend on extension code.

## Consequences

- Tool specifications and the system prompt are composed in the core and handed to
  every provider (ADR-0034, ADR-0101), so a provider cannot opt out of a
  restriction such as plan mode.
- Provider extensions contain no tool list and no approval logic.
- MCP alignment is still open.
