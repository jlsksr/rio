# ADR-0101: Plan mode: a core tool and a readable plan view

- **Status:** Accepted; amended by [ADR-0102](0102-plan-approval-policy.md), [ADR-0103](0103-plan-tool-in-every-mode.md)
- **Date:** 2026-09-11
- **Deciders:** jka
- **Decision log:** AGENTS.md D101

## Context

An agent that starts editing on a one-line request acts on an understanding nobody
checked. The maintainer asked for a planning mode like the one in the VS Code Claude
extension: the model investigates, presents a plan as a readable document, and does
nothing until it is approved.

## Decision

**A core tool.** Tools are core-owned (ADR-0020), so a plan presented through a tool call
works with every provider without provider changes. The tool is
`present_plan {title, plan}`, of kind `plan`, and goes through the existing approval gate
beside `edit` and `command`.

**A mode with enforcement.** `rio::agent::mode` is `build` or `plan`. In plan mode the
core gives the model only read tools and `present_plan`, and appends a shipped
`agent/plan.md` prompt layer (overridable). Both are applied in the core, so a provider
cannot ignore the mode. The mode is part of `agent.status`, so every frontend on a core
agrees. A plan is never auto-accepted.

**Approval continues the same turn.** Tool specifications and the system prompt are
recomposed on every step of a turn, so write tools become available on the call after
approval. Rejection keeps plan mode on and asks the model what the user wants changed.

**The plan takes the document area.** It is shown in a view where the editor normally
is, like a large proposed edit in the compare view (ADR-0028), rendered with the manual's
renderer (ADR-0100). The decision stays on the chat's approval bar. The view can be
closed and reopened; deciding, or sending a new message, dismisses it. Links in a plan are
styled but inactive.

**Every plan is filed** in the project at `.rio/plans/<timestamp>-<slug>.md` as it is
presented, including rejected ones. With no project open, no file is written.

## Consequences

- Plans work with every provider, and plan mode is enforced, not requested.
- Sharing the renderer required per-widget link state, so painting a plan cannot break
  an open manual page.
- Clearing the conversation now also removes pending review UI.
- Whether a model chooses to call `present_plan` can only be verified with a live
  provider.
- ADR-0102 moved the edit-policy choice to the plan's approval, and ADR-0103 made the
  plan tool available outside plan mode.
