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
types a real character. Escapes remain correct in one place: expected values in
tests, which must not depend on how the test file was decoded.

## Consequences

- One guard per entry point fixes the whole class of defect.
- Changing the system encoding is safe because rio never relies on it for data:
  file I/O converts encodings explicitly (ADR-0022), and configuration readers and the
  wire channel set UTF-8 themselves.
- The problem disappears with Tcl 9, which reads scripts as UTF-8 by default.
