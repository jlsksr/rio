# ADR-0122: A missing dependency names the package to install

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** jka
- **Decision log:** AGENTS.md D116

## Context

ADR-0115 fixes rio's hard dependencies — Tcl/Tk and tcllib, with tcltls for https — and
INSTALL.md names the operating-system package that carries each one. Nothing said what
happens when one of them is absent. A bare `package require` at an entry point met such a
host with a Tcl stack trace: untidy on Linux and the BSDs, and worse under `wish` on
Windows, where an uncaught start-up error becomes a modal dialog that blocks until someone
clicks it, with the trace inside. It is also the first thing a clone-and-run user can hit,
which made it release work rather than tidying.

tcltls already behaved: it is loaded on first use and reports what is missing in a
sentence (ADR-0109, ADR-0110). This brings the packages rio cannot start without up to the
same standard.

## Decision

**One table and one message, in the core, sourced first at every entry point.** The table
maps a Tcl package to the operating-system package that carries it, in the words INSTALL.md
uses. The message names the package that is missing, what to install to get it, and points
at INSTALL.md for the full table. Composing the message is separated from acting on it, so
the text can be read without a process having to die for it.

**The gate exits.** It prints the message to standard error and exits with status 1 — no
trace, because there is nothing in a trace for the person who has to install a package. The
variant used once Tk is up also raises a message box, since under `wish` on Windows there is
no console for standard error to land in, which is the platform where this matters most.

**It is not a general-purpose loader.** It is for the handful of packages rio cannot run at
all without, at the entry points, before anything else has started. An optional dependency
stays a caught `package require` at its own site and rio behaves as before without it
(ADR-0086, ADR-0115); a deferred one stays with the code that needs it (ADR-0109).

**The file is pure ASCII, comments included.** It is sourced above the entry point's UTF-8
encoding guard (ADR-0054) — necessarily, since it gates the very `package require` that the
guard's own file would die on — so its literals are decoded with the system encoding, cp1252
on Windows. A single em dash would reach the user as mojibake in the one message they must
be able to read.

**A spawned core that never greets says what to do.** The GUI's message for a local core
that exited or wedged before the handshake used to say only that the connection was lost. It
now names the command to run by hand, where the core's own complaint — most often a missing
package — is already waiting, and points at INSTALL.md.

## Alternatives considered

**Letting it stay a stack trace.** Rejected on Windows alone: `wish.exe` turns an uncaught
start-up error into a modal blocking dialog, so the worst presentation lands on the platform
with the least-prepared Tcl installation.

**Capturing the spawned core's standard error** into the GUI's failure dialog, so the real
reason shows without the user rerunning anything. Rejected: it puts a temporary file and its
lifecycle on the spawn path that runs on every normal start, to serve a failure whose output
already reaches the terminal on every platform but one.

## Consequences

- A host without tcllib or Tk gets two sentences and a package name instead of a trace, on
  the terminal everywhere and in a dialog under the GUI.
- The dependency table now exists in the code as well as in INSTALL.md, and the two must say
  the same thing; an unknown package still yields a sentence, pointing at INSTALL.md rather
  than naming a package it does not know.
- Every entry point depends on the gate file being loadable before anything else, and the
  ASCII rule applies to it for as long as it is sourced above the encoding guard.
- RELEASING.md's graceful-failure requirement for a missing dependency is met.
