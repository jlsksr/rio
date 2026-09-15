# ADR-0065: A second provider, and hardening the provider contract

- **Status:** Accepted; distribution amended by [ADR-0066](0066-installable-providers.md)
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D65

## Context

The agent had one real provider (Claude) besides the offline echo stub. A contract
with a single implementation is unproven. Users also asked for ChatGPT, and ADR-0008
had always named a local-model provider.

## Decision

A second provider was built in the tree, before any contract was frozen for outside
authors:

- It is **OpenAI-compatible**, not tied to ChatGPT. The hosted endpoint is the
  default, but the endpoint is configuration data, so the same code drives Ollama,
  llama-server, LM Studio or vLLM. It uses the OpenAI API with the user's own key,
  never the ChatGPT web interface.
- It mirrors the Claude provider: a loader, an authentication face (Bearer token),
  and an inference module mapping rio's conversation to Chat Completions.

The second implementation forced three contract changes:

1. **Per-provider keys.** A single keyed-provider slot was replaced by per-provider
   key state; `agent.key.set` and `agent.key.clear` take a provider name.
2. **Provider metadata.** `register_provider` gained `-label` and `-signup`, and
   `agent.providers` returns the list, so the GUI builds its provider picker and key
   dialog from data.
3. **A shared runtime library.** The HTTPS streaming transport and the ASCII-safe JSON
   serialisers moved to `plugins/lib/` (`rio::llm::*`), used by both providers.

Making providers installable from repositories was named as the next milestone.

## Consequences

- The contract was proven by two implementations before being versioned (ADR-0066).
- A new provider appears in the GUI without GUI changes.
- tcllib's JSON parser decodes `null` as the string `"null"`; the stream reader treats
  that string as absent.
