# rio — going live

Notes for taking rio public in an early/alpha form. Not a promise of dates — a
checklist of what has to be true before rio is handed to people who didn't write
it. Ordered by what to hit first. The *why* behind anything structural still goes
in [AGENTS.md](AGENTS.md); this file is the release-prep counterpart to
[CONTRIBUTING.md](CONTRIBUTING.md) (which is for people hacking *on* rio).

The feature set is already past an alpha bar. The risk in going live is not
missing features — it's distribution, first-run, legal, and honest platform
scoping. That's what this list covers.

## Gate 0 — Platform reality (do this first)

rio claims Linux, the BSDs, and **Windows** ([README](README.md)), but Windows is
unverified. You cannot honestly ship a cross-platform claim you haven't run.

- [ ] Launch `wish rio-gui/rio-gui.tcl` on Windows and record what breaks. Likely
      suspects: path handling (`/` vs `\`), the deploy scripts (shell — they won't
      run on Windows), the spawned-core child process + pipe transport, CRLF /
      encoding handling, and Tk theming / fonts.
- [ ] Then either fix Windows to a usable state, or **narrow the README claim** to
      the platforms that actually work and mark Windows "in progress." An honest
      smaller claim beats a broken bigger one.

## Gate 1 — Legal (hard blocker)

- [ ] Add a `LICENSE` file. With no license, nobody may legally use, fork, or
      redistribute rio. (ISC or BSD-2 fit the project's POSIX/BSD spirit; MIT for
      maximum familiarity.)
- [ ] Add `CODE_OF_CONDUCT.md` (already a ROADMAP "planned" item, due before rio
      opens to outside contributions).

## Gate 2 — Release identity

- [ ] Commit a `CHANGELOG.md`. The content is already drafted in PITCH.md — give it
      a real home outside the playground.
- [ ] Choose a version (`v0.1.0-alpha`) and git-tag the release, so a tester can say
      exactly which rio they're running.

## Gate 3 — First run & intake

- [ ] Verify graceful failure when `tcllib` / `tcltls` is missing — a clear "install
      X" message, not a stack trace. Cross-check against [INSTALL.md](INSTALL.md).
- [ ] Add an issue-reporting path (a link in the README) and a short "alpha status"
      note: what's rough, save often, and that there is **no crash recovery yet**.

## Named, and deferred on purpose

- **Crash / autosave recovery** is absent — a hard kill loses unsaved buffers. (A
  *clean* quit is guarded: `do_quit` prompts to save every modified buffer.)
  Acceptable for an alpha as long as it's stated plainly in the release notes.
