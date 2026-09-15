# ADR-0015: No terminal pane; a headless command primitive only

- **Status:** Accepted
- **Date:** 2026-06-25
- **Deciders:** jka
- **Decision log:** AGENTS.md D15 (and §4 of AGENTS.md)

## Context

Many IDEs embed a terminal. An interactive terminal emulator is the most
difficult cross-platform component an editor can carry: PTY handling, ANSI and
cursor emulation, resizing, and under a curses frontend a terminal inside a
terminal. Git and the agent, however, both need to run commands and read their
output.

## Decision

rio ships no terminal pane and no terminal emulator, not even as an option. The
bottom of the window is a one-line status bar. Interactive work and manual
testing happen in the user's own terminal, which is the documented workflow.

The core keeps a headless command-execution primitive: `exec.run {argv, ?cwd?,
?stdin?}` returns `{exitcode, stdout, stderr}`. Its rules:

- The command is an argument vector, never a shell string. There is no quoting or
  injection surface and no dependence on `/bin/sh`, so behaviour is the same on
  Windows.
- A command that runs and exits non-zero is a successful operation; the exit code
  is data. Only a failure to launch raises `io_error`.
- Output is captured as bytes, with no line-ending or encoding translation.

When command output needs to be seen, it appears in the flow that asked for it,
for example in the agent conversation.

## Consequences

- An entire UI region and its complexity are removed without losing a function
  git or the agent needs.
- Users who want a terminal keep using theirs.
- `exec.run` is synchronous and blocks the core while it runs, which is
  acceptable for short git commands. The agent's command tool needed an
  asynchronous variant with a timeout (ADR-0083).
