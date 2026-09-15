# ADR-0026: The agent's first slice, on the official API key only

- **Status:** Accepted; amended by [ADR-0034](0034-agent-system-prompt.md), [ADR-0069](0069-claude-as-extension.md), [ADR-0083](0083-agent-run-command.md), [ADR-0104](0104-stop-instead-of-step-cap.md)
- **Date:** 2026-06-27
- **Deciders:** jka
- **Decision log:** AGENTS.md D26

## Context

With a working core and GUI in place, the agent subsystem (ADR-0020) could be
started. The questions were its protocol, its provider contract, how much tool
surface to expose first, and how the first real provider (Claude) authenticates.
An early prototype signed in with a claude.ai subscription through OAuth, which
only works if the request impersonates Anthropic's own Claude Code client.

## Decision

**Protocol.** `agent.send {text}` is a streaming operation. It emits
`agent.delta` (text chunks), `agent.tool` and `agent.tool_result` (tool activity),
`agent.propose` (a write awaiting approval), `agent.message` (a completed turn)
and `agent.error` (a classified failure). Conversation state lives in the core;
the chat pane is a view. Events are structured data a terminal client could
render.

**Provider contract.** A provider is called with the conversation, the tool
specifications and a `post` callback, and posts `delta`, `tool`, `done` and
`error`. The Claude provider is split into a shared inference module (request
shaping, SSE parsing, tool-call mapping) and a thin authentication face, so the
inference code does not depend on one credential scheme.

**Tool surface.** Reads (`fs_list`, `fs_read`, `buffer_list`, `buffer_text`) run
automatically, confined to the project root and size-capped. Writes
(`propose_edit`, `propose_create`) never run automatically: the loop emits
`agent.propose` with a diff and suspends the turn's coroutine until
`agent.approve {turn, decision}`. Approved edits to open buffers go through
`buffer.replace` and are undoable. When approval arrives, the edit is located
again in the current text, so typing during review cannot make it land in the
wrong place; a vanished or ambiguous target is refused. A new message sent while a
proposal is pending closes the dangling tool call with an "interrupted" result.

**Authentication.** Only the documented Anthropic Messages API with the user's API
key (`x-api-key`), stored as a 0600 secret. The subscription OAuth path was
removed and will not be revived.

**Resilience.** Endpoint, model, API version and request timeout are configuration
data. Failures are classified (not configured, authentication rejected, rate
limited, server error, network, unexpected response) and each names the next
action. A provider failure is contained in `agent.error`.

## Alternatives considered

The claude.ai subscription path. Making the API accept a subscription token
required a forced "You are Claude Code" system prompt and an OAuth beta header.
That is undocumented, against the provider's terms, and revocable without notice.
rio does not ship code or architecture that depends on violating a service's terms
of service. Any future alternative authentication must be a sanctioned mechanism.

## Consequences

- A useful agent shipped without the command-execution surface, which followed
  under its own guardrails (ADR-0083).
- The approval gate is provider-agnostic; adding write tools needed no provider
  change.
- Later changes: a system prompt (ADR-0034); Claude moved out of the tree into an
  installable provider (ADR-0069); the step cap was replaced by a Stop button
  (ADR-0104).
