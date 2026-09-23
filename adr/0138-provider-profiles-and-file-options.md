# ADR-0138: A provider keeps several named configurations, and an option may name a file

- **Status:** Accepted
- **Date:** 2026-09-23
- **Deciders:** jka
- **Decision log:** AGENTS.md D131

## Context

[ADR-0135](0135-provider-declares-its-own-settings.md) turned every volatile detail of the
OpenAI-compatible provider into a declared option — the server URL, the model, the output
cap, the extra request JSON — so that all of them could be set from the GUI instead of by
editing Tcl on the core's disk. There was still exactly one of each.

Someone who works with both a hosted vendor and a server on their own box therefore retyped
five fields to move between them, and nothing remembered the set they left behind. Two
sharper consequences followed from the same shape. The API key was fixed to the provider
rather than to the server, so switching the URL to a machine on the local network still sent
the hosted vendor's bearer token there. And the extra request JSON had to be one line,
because a settings value is one line and the format has no continuation — while the extras
actually worth setting, the template arguments a local inference server takes, are nested
objects.

The maintainer asked for a window that manages presets.

## Decision

**Profiles are a generic core capability, which was forced rather than chosen.** A profile's
files live on the core's host ([ADR-0030](0030-always-a-channel-client.md)), and the GUI must
never learn provider vocabulary — nothing in the frontend names a model or an endpoint, which
is the whole point of [ADR-0106](0106-model-and-effort-options.md). A *manager* for one
extension therefore cannot be built without either putting that extension's words into the
GUI or putting the mechanism into the core. The core gets it, and every other provider —
Claude, and anything published later — gains profiles without a line of work.

**The core still learns nothing about what a profile contains.** It owns the location and the
format; the provider owns the keys. That is the split [ADR-0021](0021-plain-text-config-xdg.md)
already drew for the same providers' API keys and ADR-0106 drew for their settings.

- **Storage is profile-scoped and additive.** A profile is a named settings file in the
  provider's own directory, beside the flat file that provider has always written. The
  settings primitives take an optional profile; a provider that passes none behaves exactly as
  before, which is why a provider that never adopts profiles needs no change at all. Alongside
  them sit primitives to list, create, duplicate, rename and delete profile files, and to name
  the directory, so that a provider may keep per-profile files of its own beside them.
- **A provider declares the capability.** `-profiles {list switch add remove rename}` is routed
  exactly as `-options` is, and the provider inventory reports whether a provider declares any,
  so a frontend knows whether to draw a profile control without asking a second question.
- **The operations carry a name and never a meaning:** `agent.profiles.list` and
  `agent.profile.set` / `.add` / `.remove` / `.rename`. Each of the four verbs announces the
  options-changed event, because switching, removing and renaming can all change what the
  options say, and one event repaints every attached frontend rather than teaching each of them
  a second one. The active profile rides in the agent's status, so a frontend attaching to a
  core it did not start knows which configuration is running.
- **An unknown provider is refused; a provider with no profiles answers empty.** A frontend may
  therefore ask unconditionally, which is the distinction ADR-0106 had to learn.

**A profile name is deliberately wider than a provider name.** A provider name is an
identifier a user never types. A profile name is a label they choose and read back in a menu,
so spaces, dots and parentheses are allowed. What is refused is everything that could make the
name mean a different file: a path separator, `.` and `..`, a leading dot, and a leading or
trailing space — invisible, so two profiles would look identically named. The identifier rule
that guards provider names and settings keys is left alone.

**The API key is per profile, and that needed no new mechanism.** The name of the key's store
is an ordinary setting, so it became per-profile with everything else, and the key dialog
already routed through it — the per-provider keys of
[ADR-0065](0065-second-provider-contract.md), taken one level down. A
profile pointing at a server of one's own names a store of its own, which is simply empty, so
no key is ever sent to a machine that did not ask for one.

**An option may name a file, declared as a flag rather than a kind.** `file` sits beside
`free` and `refresh` on the descriptor: a flag, an operation behind it, a button beside the
field — the shape `refresh` already has — and unlike a kind it composes with whichever kind the
option already is. `agent.option.file` routes back to the provider, which both resolves the
path and **creates** the file, because a button labelled *Edit…* that opens nothing is worse
than one that opens a blank. The frontend then opens it as an ordinary tab. This is the shape
the prompt editor already has ([ADR-0070](0070-user-and-project-prompts.md),
[ADR-0105](0105-shipped-prompt-visible.md)), reached from the option side.

**What a provider adopting profiles owes.** A switch **resets to the shipped defaults and then
reads the new profile over them**; without that, a key the new profile happens to omit keeps
whatever the previous one set, which is the one way profiles leak into each other. Anything
learned from a server — a refreshed model list — belongs to the profile that server was reached
from. **The last profile cannot be deleted**: settings live *in* a profile, so there has to be
one, and refusing here is what lets everything else assume exactly one is active. A duplicate
copies the source's own side files under the new profile's name, because sharing one file would
make editing the copy change the original.

**In the GUI**, a **Profile row sits at the top of the provider's settings window**, above the
credentials and above every declared option — it decides what all of them show, so a reader who
meets it last has read the rest without knowing which configuration they were looking at.
Switching is one click there and one click in the chat strip's menu. The four rarer verbs live
in a **Manage…** dialog, modal over the settings window, rather than competing for one row's
width. The strip names the profile in its hover text but **not** in its narrow label: the strip
exists to answer *what am I talking to*, which the model already says, and a profile name can be
long.

**The extra request JSON becomes a file, replacing the inline field rather than joining it.**
One way to do it, and a file is the shape that value should always have had. It is read and
checked **per turn**, which is the only place the answer is authoritative, since the file goes
on being editable; a file that no longer parses, or that sets a request field rio emits itself,
**stops the turn and says which**, because silently dropping fields someone deliberately wrote
is the worse failure ([ADR-0113](0113-error-code-taxonomy.md)). The value is a bare filename
resolved in the provider's own directory, so it cannot point somewhere rio did not mean.

**A first run seeds a small set of example profiles, once**, keyed on the profile directory not
yet existing — the seeding rule [ADR-0039](0039-extension-repositories.md) uses for the default
repository, so a deleted example stays deleted and an edited one is never overwritten by an
upgrade. A **configuration from before profiles is carried forward rather than replaced**: what
is in the flat file is something somebody is using, so it becomes a profile of its own and
becomes the active one, with its one-line extra JSON written out as the file it should have
been. A pointer at a profile deleted by hand falls back to one that exists.

**`provider-api` goes to 5**, for the profiles capability, the profile-scoped storage and the
`file` flag, described in the file that owns the number per
[ADR-0130](0130-release-version-and-contract-versions.md). The wire protocol does not move: new
operations and new keys in an existing result are additive.

## Alternatives considered

- **A `profile` option declared like any other choice, with no core change at all.** This was
  real and was costed: switching would have worked for free, since the chat strip and the
  settings window already render a choice option, and a free-valued one would even let the user
  create a profile by typing a new name. It was rejected because rename and delete then have no
  door but a text editor, and a manager is what was asked for.
- **A new `kind` for a file-valued option** rather than a flag. A kind would not compose — the
  option would stop being a text field that happens to name a file — while a flag is the shape
  the descriptor already uses for the other capability an option can carry.
- **Leaving the key per provider.** That is precisely the leak the feature would otherwise
  introduce: a profile is chosen to change which server is talked to, and the credential is the
  part that must not stay behind.
- **Naming the profile in the chat strip's visible label.** The strip is about 340 pixels wide
  and already says which model is answering; a profile name can be long. The hover text and the
  menu carry it instead.
- **Letting a delete empty the list.** Settings live in a profile, so a provider with none would
  have nowhere to keep them, and every other part of the design would have to handle a state
  that means nothing.
- **Keeping the inline extra-JSON field beside the file.** Two ways to set one value, which is
  the drift [ADR-0085](0085-agent-config-in-preferences.md) exists to end.

## Consequences

- Moving between a hosted vendor and a server of one's own is one click, and the configuration
  left behind is still there on the way back.
- The credential follows the server rather than the provider, so switching to a machine on the
  local network cannot carry a hosted vendor's key to it.
- A provider that wants profiles declares a capability; one that does not is untouched, which is
  what makes this a core mechanism rather than a second feature of one extension.
- The extra request JSON is a real file, editable in rio like any other, and takes effect on the
  next turn with no restart — which is the same property that makes a broken edit stop that turn.
- A provider declaring `provider-api 5` cannot be installed on an older core. That is a real
  cost, priced here so the next contract bump is taken deliberately rather than by habit.
- Every guard is headless. Whether a four-button manager and a profile row sit well in the
  settings window is something only a person at a display can judge, and the seeded example
  profiles have not been driven against a live server since the change.
- Not built, deliberately: a profile that follows the project folder you open; profiles for the
  other shipped provider, which has the capability available and nothing asking for it; and
  pointing a file-valued option outside the provider's own directory, which a symlink covers.
