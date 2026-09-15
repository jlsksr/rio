# ADR-0082: A busy indicator while the agent works

- **Status:** Accepted
- **Date:** 2026-09-09
- **Deciders:** jka
- **Decision log:** AGENTS.md D82

## Context

After a message is sent, a hosted model takes several seconds before the first token
arrives, and again after each tool round trip. The agent pane showed nothing and
looked frozen.

## Decision

The chat status strip shows an animated "working" indicator: a phrase in the manner
of 1990s and 2000s productivity software loading messages ("Reticulating splines",
"Defragmenting"), followed by one to three dots. The phrase changes every few
seconds. Only ASCII periods are animated, so no font can drop a glyph.

The indicator starts when a send is acknowledged; stops on `agent.message` or
`agent.error`; pauses when an approval bar asks the user to decide (unless auto-accept
is on); resumes when the turn continues; and stops when the conversation is cleared.
It is driven entirely by existing events.

## Consequences

- The pane shows activity with no core change.
- The status strip was later split so the indicator no longer covers the provider and
  model selector (ADR-0106), and the Send button became a Stop button while the agent
  works (ADR-0104).
