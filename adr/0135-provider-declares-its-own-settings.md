# ADR-0135: A provider declares its own settings, and rio renders them

- **Status:** Accepted
- **Date:** 2026-09-22
- **Deciders:** jka
- **Decision log:** AGENTS.md D128

## Context

[ADR-0106](0106-model-and-effort-options.md) gave a provider a way to declare runtime
choices and had rio render them, so that the core never learns what "model" or "effort"
mean. What it declared them *as* was a menu: a descriptor carries a list of choices, and
the frontend draws them as radio entries in the chat status strip — a control about 340
pixels wide.

That was enough for the two things it was built for and for nothing else. The OpenAI
provider has called itself OpenAI-*compatible* since [ADR-0065](0065-second-provider-contract.md),
its manifest named Ollama and llama-server, and both the roadmap and the user manual told
the reader they could point its base URL at a server of their own. None of that was
reachable. The URL was a line in the extension's source rather than a declared option, so
the only way to change it was to edit the Tcl **on the core's disk** — which over a channel
to a remote core ([ADR-0030](0030-always-a-channel-client.md)) means a different machine — and
lose the edit at the next reinstall. That is the same complaint ADR-0106 opened with about
the model, left standing for everything else. The face also refused to run without an API
key, and its own error text advised inventing a placeholder, while the servers it was meant
to serve want no key at all.

ADR-0106's seam could not have fixed this by itself. A menu cannot hold a URL, a token cap
and a blob of request JSON. Two things were missing: a descriptor that can say *this one is
a field*, and somewhere to draw it.

A third gap surfaced on the way. A thinking model — llama.cpp, vLLM, the DeepSeek-derived
ones — streams its reasoning in a field beside its content, and the inference core read
neither spelling of it. A short thinking turn therefore rendered as an empty answer, which
is what the first probe against a real server produced.

## Decision

**A provider's option descriptor gains a rendering vocabulary, and the core still does not
interpret it.** Three keys: `kind` (`choice`, `text` or `number`), `group` (a section
heading), and `quick` (whether a frontend may also offer this in a quick control). `number`
is a rendering hint only; the provider remains the authority on what is valid, so the core
carries no range and checks none. Sections appear in the order their first member is
declared and members in declaration order within them, which is a contract a provider
orders its list against.

`quick` defaults to the constant **1**. The frontend decides separately whether a menu can
draw the option at all, by testing the kind. Both halves of that split matter: a default
derived from `kind` would put a frontend fact — that a Tk menu cannot hold an entry field —
into a core default, which is the thing ADR-0106 exists to prevent; and the constant is the
more compatible choice, because a provider written against `provider-api 2` declares no
`quick` and keeps the status-strip presence it has today.

A frontend meeting an **unrecognised** kind falls back to `choice` when the descriptor
carries choices and to `text` otherwise. Without that rule a later contract version cannot
add a kind safely, and a provider's typo becomes an unrenderable field.

**A provider settings window renders whatever a provider declares.** It is reached from
***Preferences ▸ Agent***, with a second door on the Extensions window's own row for an
installed provider the core has loaded — and, until the next core start, that row says so
instead, because an installed provider only becomes live then
([ADR-0066](0066-installable-providers.md)). The window has no OK and no Cancel: each
change is a separate write the provider has already persisted, so there is nothing to
cancel, which is the live-apply rule [ADR-0058](0058-preferences-window.md) settled for
every other setting in rio. A chooser writes on pick; a field writes on Return and on
losing focus, but only when it differs from what the core holds, because focus-out fires on
every tab-through. Every write re-reads, so the form shows what the provider accepted,
canonicalisation included. It is non-modal, like the Extensions window: it is opened from
Preferences and has to coexist with it, and a grab would hold the event loop that its own
repaint arrives on.

**The agent contract gains a `thinking` post verb.** A provider posts reasoning with it
instead of with `delta`. The orchestration loop emits `agent.thinking` and does not
accumulate the text, so reasoning is shown without entering the conversation. The frontend
renders it muted and indented under a `· thinking` marker, and it stays in the transcript
once the answer begins. The loop's tolerance of an unknown verb, which was an accident, is
now an explicit no-op with a comment: a provider written against a newer rio degrades to
silence rather than hanging the turn.

**`extensions/openai` becomes genuinely generic.** Its display name is now
**OpenAI-compatible**. A single `base_url` is the source both endpoints derive from, with
per-path overrides for a server whose paths are not under one base. An API key is
**optional**: with none stored, no authorization header is sent and the server decides. The
one case still refused up front is no key *and* the shipped hosted URL — compared against a
named constant, never a hostname test, because this face has no opinion about which hosts
belong to which vendor. Ten settings are declared in all: model, effort and reasoning; the
server URL, the output cap, the request timeout and the token-cap field; and the two path
overrides plus a free-form extra request JSON. Two of them are `quick`.

**The extra request JSON is validated and never rebuilt.** It is spliced into the body raw,
because parsing and re-serialising it would be lossy — tcllib flattens every JSON leaf to a
string, so a user's `true` would go out as `"true"`. Raw splicing raises the duplicate-key
question, and the answer is to forbid rather than merge: any top-level key rio emits itself
is refused when it is set, with a message naming the option to use instead. That set is
computed from the live token-cap field and from the key parsed out of the effort fragment,
so an upstream rename stays the one-line edit ADR-0106 made it. Embedded newlines are
flattened rather than refused, which is safe rather than lossy: a JSON document that has
already parsed cannot carry a raw control character inside a string, so every raw newline
in it is whitespace between tokens.

**`provider-api` goes to 4**, for the three descriptor keys and the `thinking` verb, and
the level is described in the file that owns the number, per
[ADR-0130](0130-release-version-and-contract-versions.md). The wire `protocol` does **not**
move: a new event and new keys in an existing result are additive.

## Alternatives considered

- **A top-level Extensions menu**, which the maintainer proposed first — the Notepad++
  shape, where extensions register their settings windows as menu items. Overruled by the
  maintainer on the counter-argument. [ADR-0085](0085-agent-config-in-preferences.md) had
  settled that a top-level menu is for fast switches and a window is where configuration
  gathers, and put the agent's keys, prompts and allow-list in Preferences on exactly that
  ground; [ADR-0067](0067-extensions-in-settings.md) had already moved *Extensions…* out
  of a top-level menu for being a management modal; and
  [ADR-0064](0064-bounded-view-menu.md) keeps the menubar within a screen. The
  analogy also does not carry: Notepad++ has a Plugins menu because its plugins contribute
  **commands**, while rio's four extension kinds contribute none, so such a menu would hold
  nothing but settings windows. It would further need a menu-contribution mechanism, which
  belongs to the still-deferred plugin UI surface, and it would have to span two homes,
  since syntax highlighters and editing modes live in the frontend while providers live in
  the core.
- **A second, separate provider extension** for compatible servers, beside the hosted one.
  This is what the maintainer asked for initially, and the counter-suggestion was taken
  instead: the existing extension already called itself OpenAI-compatible and already named
  those servers, and a second one would have duplicated the wire mapping — about 750 lines
  that then drift. Where the two genuinely differ is in defaults and in one vendor's
  400-repair machinery, and those are a handful of lines, not a codebase.
- **A shared wire module both could source.** An extension cannot reach another
  extension's files, so the shared part would have had to go into the core's provider
  runtime — making rio ship vendor-specific wire code, against the line
  [ADR-0008](0008-llm-provider-interface.md) draws between the interface the core owns and
  the wire a provider owns.
- **Deriving `quick` from `kind` in the core.** Mechanically equivalent for both shipped
  providers, and rejected for the reason given above: it teaches the core a frontend fact.
- **A `bool` kind.** The core would have to decide which string means true, and it collides
  with the convention that the first choice is the quiet one — an option declaring
  `{show, hide}` would render as a checkbox meaning "checked = hide". A two-choice `choice`
  says the same thing without the ambiguity.
- **`min` and `max` on a number.** Duplicates the provider's own validation and can
  disagree with it, and the window already re-reads after every write, so the provider's
  refusal is what it shows.
- **A `placeholder`.** `hint` already exists, and
  [ADR-0068](0068-help-text-vs-controls.md) wants help styled apart from controls
  rather than sitting greyed inside one.
- **Posting reasoning as `delta`** — the obvious fix, and worse than the defect it fixes.
  The loop appends delta text to the assistant turn it records, and re-sends that on every
  later step, so the reasoning would join the conversation and be paid for again on each
  round-trip.
- **Clearing the reasoning when the answer starts.** The chat log is append-only
  everywhere else, a mid-stream delete would take any selection the reader made with it,
  and a multi-step turn interleaves several runs of reasoning with tool calls, so there is
  no principled rule for which to erase. The setting is already the control for not seeing
  it, and a second mechanism for one outcome is the drift ADR-0085 exists to end.
  Collapsing it behind a disclosure control is a better answer that rio has no precedent
  for; it is on the roadmap.
- **Parsing and merging the extra request JSON.** Lossy, as described above.
- **A `system_role` knob** (`system` / `developer` / `user`). Every server named accepts
  the `system` role, and ADR-0106's promise is that adding an option later needs no core
  change.
- **A switch to stop sending tools.** rio's agent *is* its tools, composed in the core, so
  a provider with them off is a chat box rather than a degraded agent. The extra-JSON
  forbidden list closes that back door deliberately.

## Consequences

- A server of one's own is configured entirely from the GUI, and needs no API key. The
  promise the documentation had been making is now true.
- A provider that grows a setting needs no change in the frontend and none in the core.
  The window is rendered from the declaration.
- Reasoning from a thinking model is visible without being re-sent or re-billed, and the
  verb is provider-agnostic, so extended thinking from a hosted vendor can use it later
  with no further core change.
- The published OpenAI extension becomes uninstallable on a core older than this one. That
  is irrelevant while 0.1.0 is unreleased and the two ship together, but it is a real cost
  and is priced here so the next contract bump is taken deliberately.
- Two defects in the existing plumbing were found only because a second surface existed for
  them to show up on, and both are fixed: the options-changed event was guarded on the
  *active* provider, so a settings window open on any other one never repainted and its
  refresh did nothing at all; and the option writer raised a modal on refusal, which is
  wrong for a window with a status line and fatal to a headless run under
  [ADR-0095](0095-headless-never-asks.md).
- The settings window's write-then-repaint cycle is the one genuinely delicate piece: a
  field's own focus-out handler must not destroy the field it is running in. The repaint is
  deferred to the idle loop and scoped to the form's body, and that shape has to be kept.
- The reasoning field is verified against llama.cpp only. Other servers are unverified
  here, and one vendor's newer API sends the same field name as an object rather than a
  string; on the protocol this face speaks it is a string for every server named, and a
  non-string would render as muted noise rather than crash.
- Whether a wire encoder carries a new descriptor key is now guarded by a test that
  compares the key set the normalizer produces with the set the encoder emits, written
  before any key was added. That check exists because such an encoder is an allow-list, and
  a key it does not name disappears with every other test still passing — which had
  happened before ([ADR-0110](0110-agent-https-hostname-checks.md)).
