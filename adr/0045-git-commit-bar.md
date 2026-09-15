# ADR-0045: Commit from a bar that appears only when something is staged

- **Status:** Accepted; amended by [ADR-0081](0081-commit-message-body.md)
- **Date:** 2026-08-07
- **Deciders:** jka
- **Decision log:** AGENTS.md D45

## Context

After ADR-0044 a user could stage but not commit. Commit needs text input, and rio
had no inline input inside a dock pane yet. VS Code shows a commit box at all times.

## Decision

The git pane has a **commit bar** at its bottom that is shown only when the index
contains a staged change and hidden otherwise. It holds a single-line summary entry
with a grey placeholder and a Commit button; Enter commits.

- `git.commit {message}` runs `git commit -m` in the core and returns the new short
  hash, which the pane header briefly shows.
- An empty message is refused in the GUI without calling the core. Other failures
  are git's own messages.
- Staging another file does not hide and clear the bar, so a half-typed message
  survives.

## Consequences

- The control is present exactly when it can succeed, so "nothing to commit" cannot
  be triggered from the UI and a clean repository shows no dead space.
- This is the pattern later applied to the bulk discard button (ADR-0093): a
  destructive or conditional control appears only when it means something.
- The commit message body was added as an optional expansion in ADR-0081.
