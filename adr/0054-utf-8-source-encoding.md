# ADR-0054: Every entry point pins the source encoding to UTF-8

- **Status:** Accepted
- **Date:** 2026-09-03
- **Deciders:** jka
- **Decision log:** AGENTS.md D54

## Context

rio's sources are UTF-8 and use non-ASCII characters on purpose: the glyph icons of
ADR-0027, dashes and ellipses in UI text. Tcl 8.6 decodes a script file using the
system encoding, which on a Western Windows installation is cp1252. The first native
Windows run showed every such character as mojibake.

## Decision

Every file that is run directly, rather than sourced by another rio file
(`rio-gui/rio-gui.tcl`, `rio-core/server.tcl`, each GUI test), starts with:

```tcl
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
```

Setting the system encoding fixes every file sourced afterwards; re-sourcing fixes
the entry file itself, whose literals were already decoded. The guard does nothing
where the system encoding is already UTF-8, which includes Linux, the BSDs and Tcl 9.

## Alternatives considered

Replacing the glyphs with `\u` escapes at every use site. It avoids global state but
makes about 190 call sites unreadable and does not protect the next contributor who
types a real character. (This paragraph once carved out an exception for expected
values in tests, on the grounds that a test file could not carry the guard. The
amendment below retires it.)

## Consequences

- One guard per entry point fixes the whole class of defect.
- Changing the system encoding is safe because rio never relies on it for data:
  file I/O converts encodings explicitly (ADR-0022), and configuration readers and the
  wire channel set UTF-8 themselves.
- The problem disappears with Tcl 9, which reads scripts as UTF-8 by default.

## Amendment, 2026-09-23: the rule reaches the test files, and gains a guard of its own

The rule above is *every file that is run rather than sourced by another rio file*. A
tcltest test file is one of those — tcltest spawns a child `tclsh` per file, so the file
is that process's main script — and every test file in the tree had been overlooked.
Standing in their place was a written rule, *a test's non-ASCII value is a `\u` escape*,
which nothing checked and which was broken twice, most recently by two literals written
on Linux, where the system encoding hides the mistake.

**The claim that had stood in the way was wrong, and is worth naming because it read as
convincing.** WINDOWS.md stated that a test file cannot re-source `[info script]`,
and argued it from what the *parent* process can configure: nothing a runner sets, a
tcltest `-load` script included, happens early enough. That is true, and it answers a
different question. A file that re-reads *itself* needs nothing from its parent, and one
GUI test had been demonstrating exactly that for weeks — guarded, run as a main script,
its typographic quotes intact under a latin-1 locale.

So every test file carries the guard, as do the five suite runners and the loopback
server that one test runs as a child of its own. The runners had carried a partial
measure — setting the system encoding without re-reading — which fixed neither their own
literals nor, since each test file is a separate process, anything below them.

**The rule now has a check rather than a reminder.** `rio-core/tests/encoding.test` holds
every runnable script to the guard. The comparison is exact: the four guard lines are
ASCII, and they are compared literally once comments and blank lines are dropped, so
there is no parser to tune and no false positive to explain away. Its one exemption — a
`.tcl` that a sibling sources rather than runs — is **derived from the siblings' own
text**, not listed, so a new helper needs no edit and a new suite is covered the moment
it lands. A third check asserts that the exemption still exempts something; without it
the other two could quietly narrow to looking only at files that already pass.

**The escape requirement is retired, and escapes are kept where they say something.** A
literal now decodes correctly wherever a test runs. The two dozen latent literals
elsewhere in the suites, which passed on Windows only because the same mojibake sat on
both sides of the comparison, now test what they claim to instead of testing mangled
input. That is the case for a guard over a lint: a lint would have banned them, a guard
makes them honest. The escapes that remain are the ones that name a codepoint outright
beside a hard-coded hash, which is a reason of their own; byte-string inputs written as
`\x` stay because they are bytes rather than text, which was never the same question.

**The fault reproduces without a Windows machine.** `LANG=C LC_ALL=C tclsh` yields a
system encoding of iso8859-1 on Linux, which mangles a UTF-8 literal exactly as cp1252
does, so the whole suite can be run against the fault locally — and was, in both
directions: with the guard a reverted literal passes, and with the guard removed from
that one file its test fails by name. Being Windows-only was an accident of how the fault
had been looked for, not a property of it.

**Rejected: running each suite in a single interpreter.** tcltest's single-process mode
sources each file with an explicit UTF-8 encoding, so one line per runner would have
fixed the root as well. It was measured before being rejected: the core suite went from
clean to twenty-one failures, all in one file, from cross-file contamination in a shared
interpreter. It also trades away per-file failure isolation.

**Rejected: a lint for non-ASCII values in test files.** It needs a heuristic parser to
tell a value from a test description, since nearly all the non-ASCII in these files is
prose; it does nothing for a helper a test sources; and it forbids what the guard makes
work.
