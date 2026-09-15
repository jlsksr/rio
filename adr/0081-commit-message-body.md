# ADR-0081: An optional commit message body

- **Status:** Accepted
- **Date:** 2026-09-08
- **Deciders:** jka
- **Decision log:** AGENTS.md D81

## Context

The commit bar (ADR-0045) accepts one summary line. Larger changes deserve a body.

## Decision

A `＋` toggle on the commit bar reveals a multi-line description field below the
summary (`−` hides it). The bar starts collapsed. The GUI joins the parts as
`summary`, a blank line, and `body`, which is git's own convention, so
`git.commit {message}` is unchanged.

Enter in the summary commits; in the body Enter inserts a newline and Ctrl+Enter
commits (Ctrl+Enter works in the summary too). The body has a grey placeholder that is
never part of its text.

## Consequences

- The one-line case is unchanged, and no core change was needed.
