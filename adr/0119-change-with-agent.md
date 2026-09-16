# ADR-0119: Change with Agent: a request about the selected text, and only that

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** jka
- **Decision log:** AGENTS.md D113

## Context

The only way to point the agent at a piece of code was to describe it in the chat. The
agent then edited through `propose_edit`, which names a path and a string that must be
unique in the file, and in the same turn it could reach any other file or run commands.
The maintainer asked for the common editor gesture instead: select text, give the agent
an instruction, and have it work on that text alone.

Two constraints came with the request. The feature must not get in the way of people who
do not use an AI, least of all in a context menu. And "only the selected text" has to
mean something. Plan mode (ADR-0101) already established that a restriction on the agent
is enforced by the core, not requested in the prompt.

## Decision

**One entry, in the editor's context menu.** *Change with Agent…* is the last item of the
editor context menu (ADR-0108), behind its own separator. It is not on the menubar, so
hiding it hides the feature completely.

- It appears only while a real provider is selected. Echo, the built-in stub, cannot
  change anything, so a user who never installed a provider never sees the entry.
- A GUI preference, `agent_selection_menu` in prefs.json, hides it even then. It is on by
  default, since the provider rule already keeps it out of sight for users without a
  provider. It lives in Preferences ▸ Agent (ADR-0085), with a muted hint (ADR-0068)
  stating the Echo rule.
- The entry is greyed without a selection, and while a turn is being worked or waits on a
  decision.

**A small modal dialog** names the selection (file and lines) and takes a multi-line
instruction, with the composer's keys. The selection is taken when the dialog opens.
Sending brings the Agent pane into view, because the transcript and the review bar live
there. The turn appears as an ordinary user message with a muted note saying which
selection it is about. The dialog and the composer send through the same path.

**The wire.** `agent.send` takes an optional range as flat `buffer`, `start` and `end`
parameters, named as `buffer.replace` names a range. The core reads the selected text
from its own copy of the buffer (ADR-0003); the frontend does not send it. A missing
buffer, a range that does not exist, or an empty selection is refused before a turn
starts. An index out of range is refused, not clamped.

**What the model sees.** The user's instruction, then a block naming the buffer and the
lines, with the selected text fenced. The fence is longer than any run of backticks in
the text, so selected Markdown cannot close it. The block is part of the recorded user
message, so the conversation history shows exactly what was sent (ADR-0105).

**The core narrows the tools.** A scoped turn gets no tool of kind `write` or `exec`
except `replace_selection {text}`, a tool that exists in no other turn. There is no
`propose_edit`, no `propose_create` and no `run_command`. Read tools stay, for context,
and the plan tool follows its usual rule (ADR-0103). The narrowings compose: a scoped
turn in plan mode gets reads and the plan tool. `replace_selection` takes no path and no
match string, because the core already holds the range; there is nothing to aim
elsewhere. The scope belongs to the turn and ends with it, whether the turn finishes, is
stopped, reset or abandoned. The next chat message is an ordinary turn.

**The gate is the existing one** (ADR-0026, ADR-0028): the diff, the approval bar, the
compare view for a complex edit, and auto-accept. The proposal carries the whole buffer
before and after, so the compare view needs nothing new. When the edit is prepared, and
again when it is approved, the selection is re-anchored:

- where it was, if the range still holds the selected text;
- otherwise at the text's single occurrence in the buffer, if an edit above it moved it;
- otherwise the edit is refused as changed since the proposal.

The replacement is one buffer replace and one undo step. It is saved to disk under the
same rule as any agent edit, and a buffer with no file is never saved. The scope then
moves onto the new text, so a second `replace_selection` in the same turn replaces what
the first one wrote.

## Alternatives considered

**Prompt-only scoping:** an ordinary turn, with the selection and an instruction to touch
nothing else. The model would still hold `propose_edit` and `run_command` and could edit
elsewhere, leaving the review bar as the only guard. Rejected for the reason plan mode's
tool list is enforced in the core (ADR-0101).

**Hiding the entry by default, as an opt-in.** Users with a real provider installed have
already chosen to use an AI, and would have to find a preference before finding the
feature. **Showing it always by default**, Echo included, puts a useless AI entry in
front of everyone who has not. The chosen rule, shown with a real provider and hideable,
sits between the two.

**A nested `scope` object on `agent.send`.** It was the first shape implemented. GUI
request parameters go through the flat object encoder, so a nested dictionary would have
crossed the wire as a string that merely parses back as a Tcl dictionary: shape by
accident, which ADR-0025 rules out. The range was flattened to the parameters
`buffer.replace` already uses.

**Guessing where the selection went** when its text is no longer at its range and no
longer occurs exactly once. Any choice among several occurrences, or of a nearby changed
text, could replace code the user never reviewed. The edit is refused instead, as a stale
`propose_edit` is refused (ADR-0026).

## Consequences

- A user can hand the agent a piece of code without describing where it is, and the core
  guarantees that nothing outside it changes in that turn.
- The same selection gesture works on untitled buffers, which `propose_edit` cannot
  reach because it needs a path.
- The agent cannot run a command or read a test result through a change in the same
  turn; a request that needs that is an ordinary chat turn.
- If the user edits the selected text while a proposal waits, or duplicates it so it is
  no longer unique after a move, the edit is refused and the user selects again.
- The tool list now depends on two independent properties of a turn, its mode and its
  scope, and any new write or exec tool is excluded from scoped turns unless it is
  deliberately added to them.
- The context menu gains an entry that is not in the Edit menu's shared table, so the
  guarantee that the two menus cannot drift (ADR-0108) covers the Edit actions only.
