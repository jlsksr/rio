# ADR-0127: rio ships only artwork it can pass on

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** jka
- **Decision log:** AGENTS.md D120

## Context

ADR-0123 gave rio a window and taskbar icon and kept every artwork rio has worn in the
source tree. The artwork was stock, under a free licence that asks for the author to be
credited, and rio carried the credit — in a file beside the images and in the project's
public pitch.

Preparing a first release put the question at its real scope. An icon is not an asset
sitting in one repository. It is copied with every copy of rio anyone makes: a clone, a
distribution package, a mirror, a tarball on a mailing list. Credit is something this
project can keep. It says nothing about what the person who receives rio three copies
downstream may do with the file, and that is what a release has to be able to answer
(the legal gate of rio's release checklist). Reading the licence closely left that part
less clear than a release can be built on.

## Decision

**The question an artwork's licence must answer is whether everyone who receives rio may
redistribute it, not whether rio may use it.** Use is the easy half and the wrong test.
The file travels wholesale with the project, so a condition rio can satisfy in its own
repository but cannot pass on is a condition every downstream copy inherits without
knowing it.

**The stock artwork is removed rather than re-credited.** Attribution was never the
obstacle and adding more of it would not have touched the uncertainty, which is about
redistributing the files themselves. Deleting them is the only move that closes the
question; keeping them "for now" would have left it open in every checkout already made,
where no later decision can reach.

**The replacement is the project's own.** Same subject, so the pun on the name survives.
rio may ship it and anyone may redistribute it, which is the whole requirement.

**The rule is a condition of the folder, not of the artwork in force.** Every artwork
kept under `sources/` ships in the repository whether or not it is the one rio wears, so
each needs an origin recorded beside it — who made it, when, and on what terms rio may
pass it on — written in the commit that adds the file. That replaces the attribution file
with a note answering a different question, and keeps the answer where it cannot be
separated from the image.

**ADR-0123's mechanism is untouched, and that is deliberate.** Keeping candidates in
`sources/` with one committed line naming the one in force exists so that switching
artwork, and going back, stay one command. The artwork is expected to keep evolving; the
folder simply holds only artwork the project can pass on now.

**The new artwork is opaque — no transparent margin — so the trim ADR-0123 documents is a
no-op on it** and the tile is cut exactly as drawn, its margin included, because there the
margin is part of the design. The trim rule stands for artwork that has slack. This
candidate was put through ADR-0123's test, cut at the small sizes and viewed magnified
over dark and light chrome, and holds on both.

## Alternatives considered

**Keeping the artwork and re-reading its licence terms until the answer looked
acceptable.** Rejected: the uncertainty is about redistribution through a clone, so
leaving it unresolved leaves it unresolved in every copy that already exists. A licence
question that has to be argued is not one to put a release behind.

**Recompressing the new source losslessly.** It saved about a tenth of the file. Rejected:
the committed source stays exactly the bytes the author supplied, so that what the project
ships is the artwork as it was handed over and not a derivative nobody inspected.

**Simplifying the mechanism now that one artwork is left.** Rejected for the reason
ADR-0123 built it: the value is that switching and reverting stay one command, and that is
worth more, not less, when the set is about to grow again.

## Consequences

- The icon is an asset the project owns outright. Nothing downstream of a clone inherits a
  condition it has to track, and the release checklist's legal gate has one fewer open
  question.
- The kept-artwork folder is heavier per revision by a large factor — the project's own
  source is generated flat art and carries grain a hand drawing would not — and every
  future revision adds another to history. Accepted knowingly: an icon changes rarely, and
  keeping the supplied bytes is worth more than the saving.
- The new artwork fills less of the canvas at the smallest size than the one it replaced.
  That is the second of ADR-0123's three factors, traded for the first — contrast at the
  edge of the largest shape — which is the one that decides.
- ADR-0123's comparison of several candidates is now history: the artworks it weighed are
  gone from the tree and are not one command away. What that comparison taught about 16
  pixels survives it, and the next comparison runs the same test on candidates rio may
  redistribute.
- Nothing in rio's code, guards or documentation names an artwork — ADR-0123 kept the
  loader and its checks working from the size list and the files on disk. That is why
  replacing the artwork cost one commit and changed no test, and it is worth preserving
  the next time.
- The rule is enforced by review and by the note in the folder, not by a check. A licence
  is not a property a program can read off a PNG.
