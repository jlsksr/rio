# ADR-0130: rio is 0.1.0: semver for releases, integers for contracts

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** jka
- **Decision log:** AGENTS.md D123

## Context

rio had no version of its own. Not an unset one — no constant, no `VERSION` file, no
`--version` on either entry point. *Help ▸ About rio* showed the build identity from
`git describe`, which in a repository with no tag is a bare commit hash, and
[ADR-0076](0076-about-build-identity.md) opened by admitting exactly that: rio has no
release version yet, and the first tag is a release gate. A tester who hits a bug has
nothing to name, a changelog has nothing to attach an entry to, and "fixed in the next
one" cannot be said.

The design work, though, had largely been done already. rio had been using two
versioning idioms correctly for a year without naming either: a monotonic integer at
each seam that can break — `protocol` ([ADR-0011](0011-jsonl-wire-protocol.md)),
`provider-api` ([ADR-0066](0066-installable-providers.md)) — and semver on each
independently shipped artefact, which is an extension's `version`
([ADR-0107](0107-semver-extension-updates.md)). What was missing was rio's own number,
and, more corrosively, anywhere that said which idiom answers which question. The next
person to add a seam could only guess.

## Decision

**Two kinds of number, named, with rio's own added.**

A **release version** is semver and answers *which rio is this?* It is **one** number for
rio as a whole — core, GUI, and the bundled syntax definitions and themes — one git tag
per release, and nothing branches on it at runtime. The first is **`0.1.0`**.

A **contract version** is a monotonic integer and answers *can these two halves talk?*
There is one per seam between parties that can be updated independently, and it is
compared with a single equality or ceiling test. `protocol` and `provider-api` were
already this; `mode-api` is new.

**One literal, and for once no guard.** `rio-core/version.tcl` holds the constant and
also holds the doctrine above; the file exists as much to be read as to define a value.
The GUI sources it from the sibling tree exactly as it already sources the wire and
configuration code, so the two halves of a checkout cannot disagree and there is no
second home to hold in step. That satisfies [ADR-0117](0117-derived-facts-register.md)
by construction rather than by a test, which is the better outcome wherever it is
available.

**Where the number surfaces.** Both entry points answer `--version`. The core's greeting
reports it beside `protocol`, which is an additive change and so does not bump the
protocol, on the terms [ADR-0055](0055-core-answers-host-questions.md) set; that is how
a GUI learns which rio is on the far end of a `--connect`, the one thing the protocol
integer cannot tell it. *About* gains a **Version** row above Build — Version names the
release line, Build names the exact commit under it, and between releases Build is the
precise one, so both earn a row. The core's version appears there only when it differs
from the GUI's, since a spawned core is always this same tree.

**`mode-api`, the gap that naming the doctrine exposed.** A provider declares its
contract level and is refused when it needs more than the core implements. A mode
declared nothing — yet the mode surface ([ADR-0038](0038-editing-modes.md)) is the one
ROADMAP says *will* change, and its failure mode was the worst available: a mode built
against a newer rio fails while being sourced, and the frontend can only report that on a
stderr that `wish` on Windows has no console for. The mode is not greyed and not refused;
it is silently absent from the list. A mode now declares `mode-api`, whose level 1 freezes
the registration call, the attach and detach duties, the mode bind tag's fixed precedence
and the rule that edits reach the core through the group proxy — a surface that was
already written down and only needed a number attached.

**An absent `mode-api` reads as 1**, unlike `provider-api`, which is mandatory. The
asymmetry is deliberate: the core has required a provider's level since providers became
installable, so no provider exists without one, whereas modes have shipped without the key
since ADR-0038. Requiring it now would grey the shipped `vi` and `emacs` out of the live
repository for the whole window between 0.1.0 shipping and every manifest being re-signed,
in exchange for nothing — the key only starts carrying weight when there is a level 2. So
absence is [ADR-0019](0019-plugin-manifest-and-permissions.md)'s forward-compatibility
rule applied to rio's own manifest format.

**The too-new gate is generalised, not provider-shaped.** One table maps an extension kind
to its manifest key, the ceiling this rio implements and its default; a kind with no
contract sets nothing and can never be too new. The gate moved to the point every install
funnels through, which closed a real hole: a too-new provider had been stopped by the
core's own refusal to accept it, a check a mode — installed frontend-side with no core in
the path — never got.

**An extension's version stays its own.** ADR-0107 is unchanged and is deliberately not
tied to rio's number. That independence is what the `*-api` integers are for: they, not
rio's release version, say what an extension may rely on.

**What 1.0.0 will mean**, recorded now so it is not decided by drift: the extension and
plugin interface stops being one that will change, and the protocol becomes something a
third-party client can build against. Until then rio stays on `0.x`, which is the band
semver reserves for exactly this.

## Alternatives considered

- **`0.1.0-alpha`**, which the release gates had drafted. Semver's `0.y.z` band already
  means initial development, so the suffix restates it and then owes a promotion step that
  buys nothing. The alpha framing belongs in prose, in the README and the release notes,
  where a reader actually meets it.
- **Separate core and GUI versions.** The two are genuinely different builds only when the
  GUI reaches a remote core over `--connect` ([ADR-0030](0030-always-a-channel-client.md)),
  and that case is already governed by `protocol`, which answers it precisely. A second
  semver on each half would look like a compatibility statement without being one:
  `core 0.2.1` against `gui 0.2.0` tells a reader nothing the protocol integer had not
  already said, less reliably. One repository, one tag, one changelog, one test run.
- **Semver on the wire protocol or on `provider-api`.** A client asks a contract exactly
  one question and answers it with one comparison. Semver would offer an ordering nobody
  reads and a MINOR/PATCH split with no meaning on a wire — and the split would be empty,
  because the rule since ADR-0011 is that an additive change does not bump at all. The only
  event these numbers record is a break, which is what an integer is.
- **`theme-api` and `syntax-api` too.** A theme binds to the additive role table of
  [ADR-0024](0024-themes-as-role-data.md) and the syntax surface is stable, so both would
  be numbers nothing ever checks. Only a surface that can break earns one.
- **Making `mode-api` mandatory.** Argued above: a self-inflicted outage in the live
  repository for no gain until there is a second level.
- **A version field in the configuration and theme formats, or in a repository index.**
  All three are additive-only by construction — unknown keys ignored, unknown kinds listed
  and greyed — which is ADR-0019 already doing the work a format version would do.
- **A `VERSION` file, or a literal in each half with a guard holding them equal.** Both
  became unnecessary once it was noticed that the GUI already sources core files directly.

## Consequences

- A bug report, a release note and a changelog entry all have something to name, and the
  first tag can be cut when the remaining release gates close. About turns that tag into
  its Build row with no code change, as ADR-0076 promised.
- Whoever adds the next seam has a rule to apply rather than a precedent to interpret, and
  the rule lives in the file that defines the version, not only in the decision log.
- "Additive, no protocol bump" is not free: the core's per-operation encoders are an
  allow-list, so a key an operation returns and the encoder does not name never reaches
  the wire. Every additive key has to be added there as well. This was true before and
  undocumented; the greeting's own test is what catches it.
- A frontend must tolerate a greeting with no version, because it may be talking to an
  older core over `--connect`. That is the same forward-compatibility rule the manifest
  keys follow.
- Shipped modes must declare `mode-api` in their manifests and be re-signed at the next
  publish, but nothing breaks if a third-party mode never does.
- The documentation cannot quote a version number, since any literal goes stale at the next
  tag. What it can be held to is the claim that rio is early, which is checked only while
  the version starts `0.` — an expiry that is real and singular, because 1.0.0 is precisely
  the release most likely to ship with a paragraph still promising early days.
