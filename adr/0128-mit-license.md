# ADR-0128: rio is MIT-licensed

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** jka
- **Decision log:** AGENTS.md D121

## Context

rio carried no `LICENSE` file, no licence headers and no SPDX identifier. The
default for a work published without a licence is all rights reserved: the source
may be read and nothing more — not run, not forked, not passed on. Every other
assumption the project makes about being copied (clone it, mirror it, deploy it
onto another box) had no legal basis underneath it. RELEASING.md records this as
Gate 1, and marks it the one *hard blocker* among the release gates.

The expensive half of licensing a codebase is establishing what is actually in it.
That was already done, for its own reasons: [ADR-0127](0127-artwork-rio-can-pass-on.md)
removed the last third-party asset — the stock window icon — and replaced it with
artwork the project owns. Editor, core, protocol, agent loop, highlighters, themes
and icon are all the project's own work, so a single licence can cover the whole
tree with nothing carved out of it.

## Decision

**rio is released under the MIT License.** `LICENSE` at the repository root holds
the standard text verbatim, unedited, with the copyright held by Julius Kaiser.

The documents that had promised a licence now state it, each in its own register:
README gains a short *License* section; CONTRIBUTING answers the contributor's
question — a change sent to rio is offered under the same licence, with no
agreement to sign and no copyright assignment — and points at the icon rule as the
same question in its sharpest form for whatever a change brings with it; ROADMAP
and RELEASING keep only the code-of-conduct half of their entries open.

**The licence is also shown in the running program.** *Help ▸ About rio*
([ADR-0076](0076-about-build-identity.md)) gains a fourth facts row, `License:
MIT`, after Build, Date and Protocol. Those three identify the build; the licence
identifies the copy, which is what the person holding it needs to know and the one
fact there they should not have to find a repository to read. The name is written
in the dialog rather than read from `LICENSE` at run time — the file need not sit
beside a deployed GUI — so the fact has two homes and therefore a guard rather
than a convention: `smoke.tcl` reads `LICENSE` and holds the row to it.

## Alternatives considered

- **ISC**, the first candidate RELEASING named, and **BSD-2-Clause** beside it.
  Both grant the same permissions, both suit rio's POSIX/BSD temperament, and ISC
  says it in half the words. MIT was taken for recognition: a reader can tell what
  it permits without reading it, which at a first release is worth more than
  concision. Between licences that do the same thing, being recognised on sight is
  the only axis left.
- **Editing the licence text** — tightening the wording, dropping the shouted
  warranty paragraph. Refused: a licence that has been touched is no longer the
  licence people recognise, which would have cost exactly what MIT was chosen for.
- **Staying unlicensed until v1.** This is what the project was doing by omission,
  and it does not survive contact with a release: the first person handed a copy
  has no right to keep it.
- **Per-file SPDX headers.** Machine-readable, but rio has never carried file
  headers, and stamping every source in the tree buys something nobody has asked
  for. Tooling reads the repository-level `LICENSE` first.
- **A `license` key in extension manifests.** Plausible and forward-compatible by
  construction (unknown keys are ignored), but it changes the manifest contract
  and deserves its own record.

## Consequences

- rio may be used, modified, redistributed and sold on, by anyone, provided the
  copyright notice and licence text travel with the copies. Gate 1's licence half
  is closed; only `CODE_OF_CONDUCT.md` remains open there.
- Contributions arrive under a stated licence, so a patch from a stranger needs no
  case-by-case question about what rio may do with it.
- One licence covers the tree only for as long as that stays true. Anything
  brought in from elsewhere — code, and artwork especially — has to be something
  rio may pass on, which is the rule ADR-0127 already made a condition of the
  artwork folder.
- The About box and `LICENSE` now say the same thing in two places. That is drift
  waiting to happen, and it is registered as such: AGENTS.md §7's derived-facts
  register carries the row, and `smoke.tcl` is its guard.
- Nothing in the code depends on the licence, so there is no runtime cost and no
  new dependency. A licence is not a property a program can enforce; this one is
  held by review, by the file, and by the one test that reads it.
