# ADR-0103: The plan tool is offered in every mode

- **Status:** Accepted
- **Date:** 2026-09-11
- **Deciders:** jka
- **Decision log:** AGENTS.md D103

## Context

In the first live test the maintainer asked, in plain words, for a plan while the pane was
in Review. ADR-0101 withheld `present_plan` outside plan mode, so the model wrote a text
file called `plans/lorem_ipsum_plan.txt` instead. The feature was never entered and the UI
gave no hint why.

## Decision

`present_plan` is available in every mode. Plan mode withholds only tools that change
something. The tool's description tells the model when to use it: when the user asks, or
before a large, ambiguous or hard-to-reverse change; not for a small obvious fix.

Approving a plan leaves plan mode, and emits `agent.mode`, only if the mode was plan. The
approval result has two wordings accordingly.

## Consequences

- Asking for a plan works in any mode, matching the VS Code Claude extension.
- Plan mode's guarantee is unchanged: it makes editing impossible until a plan is approved.
  Making a plan possible and making editing impossible are separate guarantees.
- A plan presented outside plan mode is still gated and never auto-accepted.
