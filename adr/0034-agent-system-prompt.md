# ADR-0034: A core-owned, provider-agnostic system prompt

- **Status:** Accepted; amended by [ADR-0070](0070-user-and-project-prompts.md), [ADR-0079](0079-per-provider-prompts.md), [ADR-0105](0105-shipped-prompt-visible.md)
- **Date:** 2026-07-08
- **Deciders:** jka
- **Decision log:** AGENTS.md D34

## Context

rio sent the model tool descriptions but no statement of how to behave in rio:
how to use the propose-and-approve gate, or how to write code well. Adding a system
prompt raised a placement question, because the obvious mistake is to ship one
person's workflow as rio's behaviour.

## Decision

Instructions are separated into layers that must not mix:

1. **The rio agent contract:** how to act in rio (read freely, never write
   directly, propose edits for approval, match the file being edited).
2. **Coding practice:** portable defaults (smallest working change, do not invent
   APIs, ask when genuinely ambiguous).
3. **User and project specifics:** conventions of one codebase or habits of one
   person. These are never shipped with rio.

Layers 1 and 2 ship as `agent/prompt.md`, plain Markdown loaded as data, and can be
replaced by a copy in `$XDG_CONFIG_HOME/rio/agent/prompt.md`. Layer 3 is an
optional `.rio/agent.md` at the project root. `rio::agent::prompt::compose` joins
the layers; any may be absent, and with none the provider sends no system prompt.

The prompt is composed in the core and passed to the provider as an argument of the
provider contract, alongside the tool list. A provider without a system-prompt slot
ignores it. Over a remote core, the core's files shape the turn.

## Consequences

- Every provider receives the same instructions.
- Personal style stays out of rio's shipped files by construction.
- No new operation or wire change was needed.
- Later decisions added a user-wide layer (ADR-0070), a per-provider layer
  (ADR-0079) and a plan-mode layer (ADR-0101), and made the composed prompt
  visible in the GUI (ADR-0105).
