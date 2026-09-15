# ADR-0095: A headless run never asks a human anything

- **Status:** Accepted
- **Date:** 2026-09-11
- **Deciders:** jka
- **Decision log:** AGENTS.md D95

## Context

While ADR-0094 was being built, the GUI test suite deleted fixture directories while
tabs on them were still open. The new stale-buffer check correctly asked whether to keep
each deleted file open, on the maintainer's real display, once per buffer. The
maintainer answered them, so green test runs had been obtained with a human in the loop,
and those answers shaped the state later checks ran against.

## Decision

A dialog that **reports** is useful; a dialog that **asks a decision** must never reach
someone who cannot know whether their answer changes the result. Under
`RIO_GUI_HEADLESS`, dialogs go to the run's output instead of the screen.

- `tk_messageBox` and the file and directory choosers are replaced: each prints what it
  would have asked to standard error and raises an error.
- Every such dialog is recorded, and an `exit` wrapper turns a non-empty record into a
  non-zero exit status. Raising alone is not enough: most dialogs are reached from event
  callbacks, where Tcl passes the error to the background handler and the run continues
  and reports success.
- `bgerror` is replaced as well, because wish's default background error handler is
  itself a dialog.
- There is no exception for informational dialogs. An error dialog in a test means an
  operation failed unexpectedly.

The guard is keyed on `RIO_GUI_HEADLESS`, which every suite and the documented test
invocation already set, rather than on the test sandbox, which one suite deliberately
does not use.

## Consequences

- The exit status, not the summary line, is the verdict of a GUI test.
- Messages are preserved as copyable text.
- Fixture teardown closes tabs before deleting their files (`sandbox_drop_fixture`),
  except in suites that deliberately keep using a deleted file's buffer.
- A suite that forgets to set the variable is not protected.
