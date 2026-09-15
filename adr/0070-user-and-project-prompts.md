# ADR-0070: A defined place for user and project prompts

- **Status:** Accepted; amended by [ADR-0079](0079-per-provider-prompts.md), [ADR-0105](0105-shipped-prompt-visible.md)
- **Date:** 2026-09-04
- **Deciders:** jka
- **Decision log:** AGENTS.md D70

## Context

ADR-0034 gave the core a shipped base prompt and an optional project prompt, but the
files were undocumented and had no UI. A user who wanted standing instructions for
every project could only replace rio's shipped tool contract.

## Decision

The prompt is composed in three layers, in order:

- **base:** rio's shipped `agent/prompt.md`. It is rio's machinery, not a user
  setting, though it can still be replaced by an override copy.
- **system:** `system.md` in the user's XDG agent directory, with standing
  instructions for every project. It is added to the base and never replaces it, so a
  user cannot delete rio's contract by writing their own prompt.
- **project:** `.rio/agent.md` at the open project root.

Each layer is Markdown loaded as data. An empty or missing layer contributes nothing.

`agent.prompt.edit {which}` resolves the `system` or `project` file, creates it empty
if absent, and returns its path; `project` with no open project is a `bad_request`.
The Agent Prompts… dialog calls it and opens the file in rio's own editor. Because
the core creates the file, a remote core resolves it on its own disk. New files start
empty; the explanation lives in the dialog and the documentation, not in template text
that would leak into the prompt.

## Consequences

- The same instructions apply with every provider.
- No bespoke prompt editor is needed.
- A fourth, per-provider layer followed in ADR-0079, and the shipped layers became
  viewable in ADR-0105.
