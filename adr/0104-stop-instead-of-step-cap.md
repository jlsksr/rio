# ADR-0104: No step cap; a Stop button instead

- **Status:** Accepted
- **Date:** 2026-09-11
- **Deciders:** jka
- **Decision log:** AGENTS.md D104

## Context

A live turn ended at `tool_limit` after eight steps of reading. The limit dated from the
read-only agent of ADR-0026. Since then a turn can propose edits, run commands, present a
plan and, because approval continues the turn, implement it, all within the same budget.
Several larger limits were offered. The maintainer rejected the question: the VS Code Claude
extension has no step cap; it runs until done and offers Stop.

## Decision

The step cap is removed. `agent.stop` stops a turn.

- A new `live` registry maps each running turn to its coroutine, registered before the
  coroutine starts and removed when it ends. Previously turns waiting on the provider were
  not tracked at all, so reset and new messages could not reach them and they could later
  stream into a cleared conversation. Stop, reset and supersession now share one abort
  procedure.
- A turn stopped while waiting on the provider has recorded no assistant entry, so a short
  assistant note ("Stopped by the user.") is appended to keep roles alternating.
- Text the model had already streamed stays in the transcript but not in the conversation.
- The Send button becomes Stop while the agent works and returns to Send at the approval
  gate. The stop is announced as `agent.stopped`, and the transcript line is written from
  that event, so a stop from another frontend looks the same.

## Consequences

- Turns are bounded by the user, who is present (ADR-0053).
- Stopping does not refund a request already sent; the documentation says so.
- A model that loops indefinitely costs money until someone presses Stop. A high safety
  ceiling was offered and declined. This should be revisited if providers are ever used
  unattended.
