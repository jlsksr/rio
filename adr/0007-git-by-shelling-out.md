# ADR-0007: Git by shelling out to `git`

- **Status:** Accepted
- **Date:** 2026-06-24
- **Deciders:** jka
- **Decision log:** AGENTS.md D7

## Context

Git is a first-class part of rio's workflow. The options are to link a library
such as libgit2 through a compiled extension, or to run the `git` command and
parse its machine-readable output.

## Decision

rio runs `git` and parses its porcelain output. It has no libgit2 dependency.
The git layer lives in the core (`rio-core/git.tcl`) on top of the headless
command primitive (ADR-0015), so git works identically over a remote core.

Output formats are chosen to be unambiguous: `status --porcelain=v1 -b -z`
(NUL-terminated, so paths with spaces or newlines are safe) and field-delimited
`log --pretty` output. A non-zero git exit becomes a `bad_request` carrying git's
own message; a missing `git` binary is an `io_error`.

## Consequences

- No compiled dependency, and the same behaviour wherever `git` is installed.
- rio's git operations inherit git's semantics and guards, and its error messages
  are git's.
- Each git feature must choose its invocation carefully. Narrow pathspecs change
  what git reports, as ADR-0097 and ADR-0098 found for renames and untracked
  folders.
- Git's read layer started read-only; write operations were added later as
  separate decisions (ADR-0044, ADR-0045, ADR-0080).
