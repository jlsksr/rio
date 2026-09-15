# ADR-0083: The agent runs commands: gated, asynchronous, time-bounded

- **Status:** Accepted; amended by [ADR-0084](0084-command-allow-list.md)
- **Date:** 2026-09-09
- **Deciders:** jka
- **Decision log:** AGENTS.md D83

## Context

The last deferred part of the agent's tools was running commands: tests, linters,
builds, git. ADR-0053 had placed this in scope provided a human approves. The existing
`exec.run` blocks the single-threaded core until the child exits, so a timer-based
timeout could never fire while it waited.

## Decision

A `run_command` tool, of a new kind `exec`, goes through the same propose-and-approve
gate as writes.

- **Always gated.** Auto-accept applies to edits only. A command always waits for a
  human, and no separate "auto-run commands" setting exists.
- **Asynchronous.** `rio::exec::start {argv cwd stdin timeout_ms donecmd}` spawns the
  child and returns immediately. Standard output is read as it arrives, standard error
  goes to a temporary file, and the exit code is taken from `close`. The agent's turn
  yields until completion. The core stays responsive while a command runs.
- **Time-bounded.** The default timeout is 120 seconds and the maximum 600; there is no
  unlimited setting. An overrunning child is killed (`kill -TERM` on Unix,
  `taskkill /F /T` on Windows) and reported as timed out. Resetting or superseding a
  turn kills a running command.
- **Constraints.** Argument vector only, no shell. The working directory is confined
  to the project root. Any argument Tcl's `exec` would interpret as redirection or a
  pipe (`<`, `>`, `2>`, `|`, `&` and similar) is refused. A non-zero exit is a
  successful run whose code is data; only a failure to launch or a timeout is an error.

`agent.propose` gains a `kind` (`edit` or `command`), and a command proposal carries the
command, its display form and a project-relative working directory instead of a diff.

## Consequences

- The agent can run tests with a human watching, and no provider needed changes.
- Command output is returned when the command ends. Streaming output and a
  per-command cancel are deferred.
- `exec.run` remains synchronous for git's short commands.
- Re-approving the same test command every few minutes was tedious, which led to the
  allow-list of ADR-0084.
