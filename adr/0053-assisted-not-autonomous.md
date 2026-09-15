# ADR-0053: LLM integration is assisted, not autonomous

- **Status:** Accepted; amended by [ADR-0084](0084-command-allow-list.md)
- **Date:** 2026-08-23
- **Deciders:** jka
- **Decision log:** AGENTS.md D53

## Context

The agent reads the project and proposes edits for approval. The roadmap included a
command tool, test running and runtime use, which raised the question of whether rio
was turning into an agent harness and where its limit should be.

## Decision

The line is drawn at **autonomy**, not at **capability**.

- **In scope:** the agent may write files, write and run tests, run commands and use
  runtime environments, provided a human is present and in the loop. What governs a
  command is approval, not prohibition.
- **Out of scope, as a matter of identity:** rio acting on its own while no human is
  interacting: scheduled, unattended or self-directed operation.
- **The restriction binds rio, not plugins.** A plugin author may build unattended
  behaviour on the plugin surface; rio does not impose its own restraint on others.

The test for a proposed feature: does it need a human in the loop to act? Then it is
in scope. Does it act unattended, on a schedule or on its own initiative? Then it is
out.

## Consequences

- The command tool (ADR-0083) and plan mode (ADR-0101) are in scope.
- Schedulers, background agents and similar features are not built into rio.
- ADR-0084 refined the wording: a human-authored allow-list is standing approval, not
  autonomy. The rule is that no trust decision is made silently by the machine.
- Removing the step cap (ADR-0104) is consistent with this: a human is watching and
  can stop the turn.
