# ADR-0137: A top-level Extensions menu; each extension configures itself

- **Status:** Accepted
- **Date:** 2026-09-23
- **Deciders:** jka
- **Decision log:** AGENTS.md D130

## Context

[ADR-0135](0135-provider-declares-its-own-settings.md) gave a provider a settings window
and put it in ***Preferences ▸ Agent***. The maintainer had proposed a top-level
Extensions menu instead, was given a counter-argument, and took it. Once the code existed,
two things that counter-argument never addressed were plain:

- **The pane mixed two different things.** rio's own agent settings — the agent mode, the
  compare-complex-edits toggle, the prompt layers, the command allow-list, the
  change-with-agent toggle — sat interleaved with the settings of one particular provider.
- **It did not scale.** The Agent pane ended in two loops over the installed providers,
  one emitting an API-key button and one a settings button, so every provider installed
  added two entries to a pane that is rio's rather than theirs. Even with a single
  provider installed, that provider had two separate doors to its own configuration.

The counter-argument's load-bearing objection was also false, which is why the wrong call
was made and is worth recording. It held that such a menu would need a menu-contribution
mechanism, which belongs to the still-deferred plugin UI surface
([ADR-0018](0018-declarative-ui-contributions.md)). It needs nothing of the sort: the menu
is filled from the enumeration of installed providers the frontend already keeps and
already uses to fill its provider cascade. The second objection — that extension settings
span two homes, providers in the core and highlighters and modes in the frontend — is
answered by a menu that merges two enumerations rather than caring where either comes
from. And the Notepad++ analogy answered a claim nobody had made: the request was for
settings windows, not for command contributions.

## Decision

**The line everything is held to: what the extension declares lives in the extension's own
window; what rio owns lives in Preferences.** That line is worth more than the menu it
produced. By it, an API key is the provider's — one provider's key is meaningless to
another — while the per-provider prompt layer
([ADR-0079](0079-per-provider-prompts.md)) and the per-provider scope of the command
allow-list ([ADR-0084](0084-command-allow-list.md)) are rio's own mechanisms merely keyed
by a provider's name, and stay in Preferences ▸ Agent.

[ADR-0085](0085-agent-config-in-preferences.md) is unharmed, and its reach is now stated:
it governs where **rio's** settings gather, not an extension's.

**The menu.** `Extensions` sits between Settings and Help — rio's own configuration first,
then what has been added to it, then Help last. It leads with ***Extensions ▸
Browse…***, the installer, which therefore leaves the Settings menu
([ADR-0067](0067-extensions-in-settings.md)). That entry was labelled *Extensions…* when
this record was written and was renamed days later: the menu, the entry and the window it
opens all carried the same noun, and only one of them was naming anything, so the entry
names the act instead.
Below a separator it carries one door per installed extension that has something to
configure, and a disabled placeholder when none has, so the menu is never empty. Every
entry below that separator names an *installed* extension, so the manual can teach the
form of such a path but never a path itself; the first entry is the only one a guard can
hold against the widgets.

**It is a merge, not a provider special case.** The doors come from the provider list and
from a registry a frontend-side extension can add to when it loads, in the idiom the
editing-mode registry already uses ([ADR-0038](0038-editing-modes.md)). The registry is
empty today; the merge is the point, and it is the answer to the two-homes objection
above.

**The menu stays bounded by construction.** [ADR-0092](0092-theme-picker.md) states that
no menu in rio is data-driven and unbounded, and this one is data-driven. Past a fixed
number of doors it emits a single entry that opens the bounded picker Switch to Tab… and
Theme… already use ([ADR-0074](0074-buffer-picker.md)).

**The API key becomes a row in the provider's own window** — a credentials group rendered
first, with a masked field, a reveal, Save, Clear, and a note saying whether a key is
stored. The separate key dialog is deleted; folding it in left it with no caller, and a
second door is the drift ADR-0085 exists to end. One window therefore carries two
interaction contracts: a key commits on an explicit **Save**, while a declared option
applies on Return or on losing focus. That is the right way round — a key is pasted and
committed deliberately — and the window's opening line says so rather than leaving it to
be discovered.

**A provider that holds a key earns a window on the key alone**, declaring no options at
all. Gating the window on declared options would leave such a provider nowhere to set the
one thing it has. Both doors — the menu, and the row in the Extensions window for a
provider just installed — ask the same question, after a review found them briefly
disagreeing: with the row still gated on declared options, exactly the provider the new
question exists for was reachable from one door and not the other.

## Alternatives considered

- **Keeping the settings in Preferences ▸ Agent**, as ADR-0135 decided. Rejected on the
  two grounds above: it mixes rio's settings with one extension's, and it grows by two
  entries for every provider installed.
- **The key as a button in the window that opens the old dialog.** A door to a door, and
  the weaker answer to the mixing complaint: a provider's configuration would still be in
  two places.
- **Leaving Extensions… in the Settings menu** and giving the new menu only the
  per-extension doors. Rejected: "my extensions" would then be split across two menus.
  ADR-0067's own reasoning is untouched and is still why the item is not back under View —
  it is a management window, not a pane toggle. What changed is that a better home
  appeared.
- **Accepting that the menu is short in practice** rather than bounding it. Rejected:
  ADR-0092 is absolute, and a bound that holds by construction is cheaper than a bet on
  how many extensions anyone installs.
- **Placing the menu before Settings**, which the first draft did. The maintainer chose
  after: rio's own configuration first, then what has been added to it.

## Consequences

- The menubar is File · Edit · View · Find · Compare · Settings · Extensions · Help.
- A provider's whole configuration — its key and everything it declares — is behind one
  door, and installing another provider adds one menu entry rather than two buttons in
  rio's own pane.
- Both providers' not-configured and authentication-failure messages named Preferences ▸
  Agent and now name the provider's own door, which is the correction ADR-0085 made in the
  other direction.
- Nothing in the provider contract moved, so `provider-api` does not change. Only where a
  frontend draws a provider's settings changed.
- No extension kind but `provider` has a settings door. The registry is there and empty
  because no mode, theme or highlighter has anything to configure; inventing the need would
  be the speculative half of the deferred plugin UI surface.
- The guard that holds the manual's menu references against the real menubar had to be
  repaired. It resolved a quoted `Menu ▸ Item` by reading the text before the separator as
  the menu's name, which was unambiguous until a menubar menu and a Preferences category
  came to share the name *Extensions* — at which point a window path was read from its
  middle and reported against a menu it was never about. A segment inside a path must now
  follow one that resolved too, so the head of the chain decides whether the path names a
  menubar menu at all. A first attempt applied that rule to every segment and silently
  stopped reporting nearly everything it had been reporting: **a guard that passes by
  seeing less is worse than the drift it was watching for**, so a change to one is checked
  against the findings it already made, not only against the case that prompted it.
