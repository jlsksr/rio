# ADR-0008: LLM access behind a stable provider interface

- **Status:** Accepted
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D8

## Context

rio integrates AI agents, but specific model services change constantly: APIs are
versioned and renamed, vendors come and go, and local model servers each have
their own conventions. Wire details of any one service should never reach the
core.

## Decision

The core defines a stable **provider interface**: given a conversation and the
available tools, stream assistant output and tool-call requests. Concrete
providers implement it and absorb the service-specific wire details (HTTP, JSON,
SSE, authentication). Providers are extensions, not core modules. rio's own
providers dogfood the interface: a hosted one (Claude) and an
OpenAI-compatible one that also covers local servers such as Ollama and
llama-server.

A provider is a protocol participant over the thin extension seam. It does not
need the full plugin platform of ADR-0016 to ADR-0019, so providers could ship
with the first agent slice.

## Consequences

- Vendor churn is contained in provider code.
- The provider contract has to stay small and be versioned once outsiders build
  against it. ADR-0065 hardened it with a second implementation and ADR-0066
  versioned it as `provider-api`.
- The division between the core loop and providers is described in ADR-0020.
