# ADR-0140: On macOS, platform facts are asked of Tk, not assumed

- **Status:** Accepted
- **Date:** 2026-09-29
- **Deciders:** jka
- **Decision log:** AGENTS.md D133

## Context

rio had never run on a Mac. The first run was on macOS 27 on Apple Silicon, without root.
Homebrew was present but not writable, and the system Tcl was Apple's 8.5.9, so Tcl/Tk
8.6.16 (Aqua), tcllib and tcltls were built from source into the user's home directory.

Running the full suite against that build found three faults and one surprise:

- Every fixed-width font in rio asks for the family `monospace`. That name is a fontconfig
  alias. Aqua does not know it and falls back to the proportional system UI font, so the
  editor was not monospaced. Every width measured from one column was wrong with it.
- The headless sizing block from ADR-0134 (D127) left Tk's Aqua event loop spinning, so
  every later full `update` hung.
- The test fixtures built paths from `$TMPDIR`, which on macOS goes through the `/var`
  symlink. The core normalizes every path it reports, so the two never matched.
- Aqua `wish` sends its stdout and stderr to `/dev/null` when its stdin is `/dev/null`,
  because it takes that for a Finder launch.

## Decision

**The GUI resolves `monospace` through Tk's own metrics.** `mono_family` keeps `monospace`
where `font metrics {monospace 12} -fixed` says it is already fixed-width, which is the case
on X11. Anywhere else it substitutes the family of Tk's `TkFixedFont`: Menlo on macOS,
Courier New or Consolas on Windows. The theme fonts, the user's editor-font override and
every literal chrome font go through it. The core's theme data keeps saying `monospace`,
because turning a portable intent into a concrete family is the GUI applier's job (ADR-0024).

**On Aqua, the headless sizing block leaves `overrideredirect` set** after withdrawing the
window. Clearing it is the one step, out of four, that triggers the spin. A headless run
never shows the window again.

**Test fixtures start from a canonical `$TMPDIR`**, set once in `rio-gui/tests/sandbox.tcl`.
That way they are in the form the core reports.

**GUI suites on macOS are run with a non-empty stdin**, as in `: | wish …`. That keeps
their output.

## Alternatives considered

- **A per-platform table of font families.** Rejected. It guesses about the platform in the
  way ADR-0055 (D55) rules out, and it duplicates `TkFixedFont`, which Tk maintains for
  exactly this purpose.
- **Change the theme's default family to `TkFixedFont` in the core.** Rejected. The theme is
  data that a future TUI also reads, and a Tk named font means nothing there.
- **Skip the off-screen sizing map on Aqua.** Rejected. The map is what gives a headless
  run a real layout, and the spin needs all four steps together; dropping only the flag
  reset is the smallest change that avoids it.
- **Normalize paths in the GUI before comparing them.** Rejected. Both operands come from
  the core, which has already normalized them. A client-side normalize is also wrong across
  platforms, as ADR-0055 records.

## Consequences

- rio's editor, chat and chrome are fixed-width on macOS. Windows probably benefits too,
  but that has not been verified.
- The full suite passes on macOS 27 with a from-source Tcl/Tk 8.6.16. The installer is still
  unverified there: neither branch of `install-unix.sh` was run.
- Anyone running GUI suites on macOS from a non-terminal context has to supply a stdin, or
  they lose the output. The exit code still gives the verdict.
- `font.tcl` holds the fixed-width property on every platform the suite runs on.
