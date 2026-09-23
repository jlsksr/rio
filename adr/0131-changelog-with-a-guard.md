# ADR-0131: rio has a changelog, and a guard keeps it current

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** jka
- **Decision log:** AGENTS.md D124

## Context

[ADR-0130](0130-release-version-and-contract-versions.md) gave rio a version for changelog
entries to attach to, and rio still had no changelog. What history existed sat at the foot
of `PITCH.md`, a landing-page draft that DOCS.md forbids editing except on the project
owner's explicit request. rio's history therefore lived in the one document nobody was
allowed to maintain, and it showed: the newest entry there named D108 while the decision
log had reached D123. Fifteen decisions — https repositories, certificate exceptions, the
language picker, the signing work, the licence, the version itself — had no entry at all,
and nothing had failed because of it.

Only half of that is content work. Writing the missing entries and giving them a home is
content work. What stops the file going stale a second time is a decision, and it is the
one AGENTS.md §7 already took for the manual
([ADR-0117](0117-derived-facts-register.md)): a fact with two homes needs a guard, because
"keep them in sync" is an instruction addressed to whoever happens to be editing, and that
is exactly who failed here.

## Decision

**`CHANGELOG.md` at the repository root, in
[Keep a Changelog](https://keepachangelog.com/) form.** One `##` section per release, with
`### Added`, `### Changed` and `### Fixed` beneath it, newest first. rio usually writes its
own formats. Here it does not: a changelog is read by people who have never seen rio, often
through a packaging tool, and it is the one document whose *shape* carries meaning — *Added*
against *Fixed* answers "should I upgrade?" before a word is read. That is the same trade
[ADR-0128](0128-mit-license.md) made for the licence. Recognition beats a house dialect for
the documents a stranger meets first.

**Every entry carries rio's own citation** — the decision it implements, a representative
commit, and the date it landed. Without it an entry is prose; with it the document can be
checked against the repository. An entry states a change **as it landed**: where a later
decision amends an earlier one it earns its own entry rather than editing the history it
changed.

**Rewritten, not transplanted.** PITCH's narrative entries were cut to changelog length —
the essay is what AGENTS.md is for — and the decisions that had never been written up at
all were written from their AGENTS.md sections, so the file arrived current rather than
arriving with a known gap.

**`PITCH.md` keeps its copy, frozen**, byte for byte, under a note saying that it is
historic, that it stopped at D108, and where the live changelog is. PITCH itself goes away
at the first release, and the duplicate goes with it; until then the original wording of a
hundred entries is worth more than the tidiness of deleting it. Leaving it *unmarked* would
have been the worst of the three: two changelogs, one silently stale, which is the drift
this decision exists to end.

**The guard is the substance.** `rio-core/tests/changelog.test` runs with the core suite
and holds the changelog against AGENTS.md in both directions:

- Every decision in AGENTS.md is cited by an entry, **or** named in an exemption table with
  its reason written out. A decision therefore cannot land without either a line a user can
  read or a stated case that no user could have seen it.
- The exemptions are themselves checked. One naming a decision that does not exist, or one
  whose decision has since been written up, fails — so the table cannot quietly grow into a
  backlog.
- A citation pointing at a decision AGENTS.md does not have fails too; that is a typo'd
  number, and a reader who follows it lands nowhere.
- The release heading is read against the version literal of ADR-0130, the section names
  and their order are the format's, and entries are newest-first within a section.
- Where there is a git repository to ask, every cited commit must resolve and every date
  must be the one its commit carries. The dates are looked up, not proofread, which is §7's
  "assert against behaviour" rule reached as far as a document allows.
- Two further checks hold PITCH's copy frozen: it must say it is no longer maintained and
  point at the live file, and it may cite no decision past D108.

**CONTRIBUTING.md carries the rule for human contributors** — a change to what a user sees
adds its entry in the same commit — but the rule is not the mechanism. A rule without a
guard is a backlog item.

## Alternatives considered

- **Keeping rio's month-grouped narrative format**, which is what PITCH had. It conveyed
  nothing about the nature of a change and nothing about which release a change belongs to,
  and the release is the fact ADR-0130 had just made available.
- **Deleting PITCH's copy.** It would discard the original wording of every entry in order
  to remove a duplicate that disappears with its own file at the release.
- **A written rule in CONTRIBUTING and no test.** Rejected on §7's own argument, and on the
  evidence: PITCH had the rule and fell fifteen decisions behind anyway.
- **A format-only guard** — citations resolve, ordering holds, no second copy. Nothing in it
  detects a *missing* entry, which is the drift that actually happened.
- **An `## [Unreleased]` section.** Everything so far is 0.1.0, so the heading reads
  `[0.1.0] — unreleased` and takes a date when the tag is cut. That keeps one section per
  release rather than a section that has to be renamed into one.
- **A link-reference block** resolving the release heading to a tag URL. Deferred until a
  tag exists to link to; RELEASING.md tracks it with the tagging step.
- **Generating entries from `git log`.** The log is commits; a changelog is changes, and the
  difference is the whole value of the document.
- **An entry for this decision itself.** Impossible: the entry would cite the commit that
  creates the changelog, which does not exist while the entry is being written, and a file
  announcing its own existence tells its reader nothing. It is written down as an exemption
  instead, which put the table to use before anyone had to remember it exists.

## Consequences

- A user, a packager and a tester can see what changed without reading the design log, and
  the release-identity gate that asked for a changelog is closed. The heading takes its date
  from the `v0.1.0` tag, with no other edit.
- Every decision from now on ends in one of two places: an entry, or a line in the exemption
  table saying why a user could not have seen it. Both are visible in review; neither can be
  forgotten silently.
- The guard depends on the citation format, so an entry written freehand fails until it
  carries a decision, a commit and a date. That is a small tax on writing an entry and the
  reason the document stays verifiable.
- Checking dates against git means the guard is weaker in a checkout with no `.git` — a
  release tarball, for instance. Those checks skip rather than fail; the register and shape
  checks still run.
- `PITCH.md` is now governed by a test as well as by the rule against editing it, and it
  stays that way until the file is removed at the release.

## Amendment, 2026-09-23: `PITCH.md` is gone, and the freeze went with it

The decision above kept `PITCH.md`'s copy of the changelog frozen rather than deleting
it, on the grounds that the original wording of a hundred entries was worth more than the
tidiness — *until the file went away at the first release*, which it now has. PITCH.md was
deleted ahead of the `v0.1.0` tag rather than at it: the original wording is in git, which
is where a superseded draft belongs, and a second changelog kept alive in the tree is
exactly the shape this decision was taken to end. What PITCH had that had landed nowhere
else — the experiment framing, the by-the-numbers block, the icon's provenance — moved
into README.md in the same commit.

So two of the consequences above have expired. The two freeze checks
(`changelog-pitch-copy-is-marked-historic` and `changelog-pitch-copy-does-not-grow`) are
deleted with the file they watched, and PITCH is no longer governed by a test because
there is nothing left to govern. The two checks that carry the weight — every decision in
AGENTS.md cited or exempted, and every commit and date resolved against git — are
untouched and still hold `CHANGELOG.md` both ways.

AGENTS.md D124 carries the same amendment.
