# ADR-0129: An extension payload carries its licence inside it

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** jka
- **Decision log:** AGENTS.md D122

## Context

[ADR-0128](0128-mit-license.md) licensed rio under MIT with a single `LICENSE` at the
repository root, on the reasoning that rio is copied wholesale: clone it, package it,
mirror it, and the licence arrives with every source file in the tree. That record
declined per-file headers for the same reason.

Extensions are the one part of rio for which that is false. An extension is fetched from
a repository over plain http ([ADR-0039](0039-extension-repositories.md)) and installed
file by file, and where the files land depends on the kind: a `mode` or `syntax` payload
is written into the user's `~/.config/rio/modes/` — a directory **shared with every other
extension of that kind** — a `theme` is handed to the core and kept in its theme store,
and only a `provider` gets a directory of its own. Nothing shipped *beside* a payload
travels with it, and for the shared directories nothing could: two extensions cannot both
install a file called `LICENSE` there.

So rio's own extensions, MIT in the tree from the moment ADR-0128 landed, arrived on a
user's disk as files that could not say what they were — at exactly the point where the
question gets asked, which is the second copy rather than the first.

[ADR-0127](0127-artwork-rio-can-pass-on.md) had already put the test in the right form
for artwork: the question is not whether rio may use something, but whether everyone who
receives it may pass it on. A payload is in the same position as the icon was, and more
exposed, since being fetched by strangers is the ordinary way to obtain it.

## Decision

**Every payload rio's own extensions ship carries the full MIT notice** — copyright line,
permission paragraph and warranty disclaimer — inside the comment block the file already
opens with. That is `extensions/claude/*.tcl`, `extensions/openai/*.tcl`,
`extensions/emacs/emacs.tcl`, `extensions/vi/vi.tcl`, and `night-theme/night.theme` in the
publishing repository. Their tests are not stamped: tests stay behind.

The notice is the full one and not a pointer. MIT asks for it to be included in all
copies, and a file that travels alone is the case that requirement exists for; "MIT, see
LICENSE" would send a reader to a file that is not there.

Theme files take `#` comments like any conf file
([ADR-0021](0021-plain-text-config-xdg.md)), and
`rio::theme::put` validates by parsing and then stores the text verbatim, so the notice
reaches the user's theme store intact.

The publishing repository is a separate git repository and had no licence of its own; it
gets the same `LICENSE`. Its README states the terms and says plainly that another
publisher's extensions are theirs to license — a rio repository makes no claim about what
it serves, because the sources list is the trust list.

CONTRIBUTING states this to extension authors as a consequence of the format rather than
as a house rule: nothing beside a payload arrives with it, so a licence has to be in the
file. rio neither asks for one nor checks for one.

## Alternatives considered

- **Leaving it to the root `LICENSE`.** This is what ADR-0128 already did, and it is
  correct for everything that travels with the tree. It simply does not reach a file
  installed on its own.
- **A `LICENSE` file among an extension's `files`.** Defeated by where the files go: the
  shared `modes/` and `syntax/` directories would have every extension's `LICENSE`
  colliding on one name, and a theme's payload is not written as a file at all.
- **A `license` key in `rio-extension.conf`.** The manifest is installed for a provider,
  and the install prompt could show the licence as consent is given. But it changes the
  manifest contract, it is advisory — nothing can verify a claim made in a `.conf` — and
  the notice in the payload is the part with legal work to do. Deferred, now for a reason
  rather than by omission.
- **An SPDX tag alone.** Machine-readable and one line, but it identifies a licence
  without granting it, which is the wrong half for a file with no licence beside it.

## Consequences

- An extension file that leaves rio — installed, copied out of a config directory, mailed
  on, pasted into someone else's repository — carries its terms with it.
- Payload files open with roughly twenty lines of notice before their description. That is
  the visible cost, and it is paid once per file.
- ADR-0128's refusal of file headers now has a stated boundary rather than being a flat
  rule: the licence lives with whatever unit actually travels — the repository for rio,
  the file for an extension. A future decision about some other separately-distributed
  artefact has the test to apply.
- Nothing enforces this. No test can read a licence off a payload, and rio must not start
  refusing extensions over what their comments say. It is held by review, as ADR-0127's
  artwork rule is.
- The publishing repository's `SHA256SUMS` covers every served file, so stamping the
  payloads invalidates its signature. Re-hashing and re-signing is the ordinary publish
  step (`SIGNING.md`), not a new obligation — but it is required before the next upload.
