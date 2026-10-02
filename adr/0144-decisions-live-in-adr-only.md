# ADR-0144: Decisions live in adr/ only; AGENTS.md is instructions

- **Status:** Accepted
- **Date:** 2026-10-02
- **Deciders:** jka

## Context

AGENTS.md held the whole decision log: D1 to D136, 107,000 words, 676 KB. Every agent
session loaded it. The same decisions were also filed here, one record each
([ADR-0131](0131-changelog-with-a-guard.md) and `check.tcl` held the two series together).

jka's instructions of 2026-10-02 ask for few words in everything a human reads.

## Decision

- **A decision is recorded here and nowhere else.** A new one takes the next free
  number and is cited as `ADR-NNNN`.
- **AGENTS.md is instructions for agents:** jka's rules, the architecture in one
  drawing, how we work, and the derived-facts register
  ([ADR-0117](0117-derived-facts-register.md)).
- **D1 to D136 stay valid names.** Source comments and the changelog cite them. Each
  record's **Decision:** line carries its D number; D1 to D111 share the record's number.
  No new D numbers are issued.
- **The guards read the records.** `check.tcl` holds the D numbers gap-free.
  `changelog.test` holds every decision, D or ADR, against CHANGELOG.md.

## Alternatives considered

- **Keep the log beside the records as an archive file.** Two homes for one fact again.
  Git has it: `git show 1400edf:AGENTS.md`.
- **Keep issuing D numbers.** Two numbers per decision, seven apart, forever.

## Consequences

- An agent session starts about 170,000 tokens lighter.
- The old log's implementation detail (test counts, proc names, bug narratives) is in git
  only.
- The open questions of the old §6 that were still open moved to ROADMAP.md.
