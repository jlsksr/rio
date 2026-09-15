# ADR-0102: The edit policy is chosen when a plan is approved

- **Status:** Accepted
- **Date:** 2026-09-11
- **Deciders:** jka
- **Decision log:** AGENTS.md D102

## Context

The agent pane had no control for switching between reviewing edits, auto-accepting
them, and planning. Two independent flags existed in the core, `mode` (build or plan) and
`auto_accept` (edits only), and the status strip derived three states from them by letting
plan mode take precedence. Auto-accept could therefore be armed invisibly while the pane
said "plan mode", and edits would apply unreviewed once the plan was approved.

A first fix cleared auto-accept whenever plan mode was chosen. The maintainer rejected it:
the user should decide how the work proceeds after reading the plan, and should be able to
edit the plan first.

## Decision

- **The plan's approval bar asks the question.** `Approve ▾` offers "review each edit" and
  "auto-accept edits". Approving with auto-accept sets the flag, then approves. The flag is
  set first, so a refused setting leaves the plan awaiting a decision.
- **Plans can be edited.** Edit plan closes the plan view and opens the plan file
  (ADR-0101) in the editor. At approval the core reads the plan again from the live buffer
  if open, otherwise from disk. If the text changed, the tool result tells the model the
  user edited the plan and includes the approved text. A deleted file falls back to the
  plan as presented.
- **One control, three names.** The chat header has a mode menubutton labelled `Plan`,
  `Review` or `Auto`, with a tooltip. Its state is derived from the two core flags and never
  stored separately; one writer sets it and resynchronises on refusal. The status strip no
  longer repeats the mode. Settings ▸ Agent Mode and the Preferences radio buttons use the
  same variable and writer.
- Choosing Plan leaves auto-accept unchanged. While planning, "Plan" fully describes what
  the agent may do.

## Consequences

- The UI cannot claim a state the agent is not in.
- Plan files became the single representation of an agreed plan.
- The core keeps two flags because they answer different questions (may it change
  anything; does a change wait for approval); the three-state control is a view of them.
