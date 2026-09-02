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

- [x] Launch `wish rio-gui/rio-gui.tcl` on Windows and record what breaks.
      **Done 2026-09-02**, Windows 11 Pro 22631, Magicsplat Tcl/Tk 8.6.16, Git for
      Windows 2.55.0.5. **rio launches, spawns its private core over the pipe, and
      edits.** Findings below.
- [ ] Then either fix Windows to a usable state, or **narrow the README claim** to
      the platforms that actually work and mark Windows "in progress." An honest
      smaller claim beats a broken bigger one.

### Gate 0 findings — first Windows run (2026-09-02)

What was **not** a problem, so nobody re-investigates it: the spawned-core child +
pipe transport (`rio-gui/tests/pipe.tcl` fully green — `auto_execok tclsh`, the
`wish`→`tclsh` name fallback, `open |… r+`, and the `-translation lf -encoding utf-8`
channel all behave); path handling; Tk theming and fonts; persistence (Tcl provides
`HOME` on Windows, so the XDG fallback resolves — see WINDOWS.md §3). `syntax`
532/532, `rio-core` 375/388, and the `pipe` / `remote` / `repos` / `split` / `stale` /
`vi` / `modes` / `find` GUI suites are clean.

Three real causes account for everything that failed:

1. **Tcl 8.6 reads `.tcl` source files in the system encoding, not UTF-8** — cp1252
   on a Western Windows install. Every non-ASCII literal is mis-decoded, so **D27's
   monochrome-Unicode iconography renders as mojibake**: `●` (unsaved dot), `⟳`
   (refresh), `▸`/`▴`/`▶`, `✓`, `×`, `·`, arrows, `…`, `—`, curly quotes. 192
   non-comment lines across the tree carry such literals, 125 of them in
   `rio-gui/rio-gui.tcl`. This is the one **user-visible** defect and the only one
   that makes rio look broken. It also causes all 9 `smoke.tcl` failures (including
   `pane: scrollbar hidden when list fits` — one glyph becomes three characters, so
   rows get wider and the list stops fitting) and the `fs-read-multibyte` core
   failure, where *Windows produced the correct answer* and the test's own expected
   literal was the mis-decoded one. Tcl 9 defaults source to UTF-8; on 8.6 the fix is
   to keep source ASCII (`\uXXXX` escapes, ideally via one named glyph table, which
   suits D27) — the entry script cannot be `source -encoding utf-8`'d by itself.
   **Wants its own decision entry.**

2. **A leaked channel when a parse throws between `open` and `close`** — a real rio
   bug, invisible on POSIX, biting on Windows because an open file **cannot be
   deleted**. The shape, four times in `rio-gui/rio-gui.tcl`:

   ```tcl
   if {[catch {
       set f [open $path r] ; fconfigure $f -encoding utf-8
       set d [json::json2dict [::read $f]] ; close $f   ;# never reached if json2dict throws
   }]} return
   ```

   at `prefs_load` (4286), `sources_load` (4413), the extensions ledger (4454) and
   `keymap_resolve` (5807). Consequence: after rio reads **one corrupt `prefs.json`
   or `keys.json`** — precisely the case each has a passing "corrupt file tolerated"
   test for — the file stays locked for the life of the process, and rio can never
   delete or reset it again. Confirmed cause of the 3 `keymap.tcl` failures and the
   `session.tcl` abort. Fix: `close` in a `finally`, or read the file in a helper
   that closes on error.

3. **POSIX-only assumptions in test helpers** (test-side, not product):
   `rio-core/tests/stdio.test` writes to `/dev/null` (3 failures);
   `rio-gui/tests/highlight.tcl:31-32` takes `[file dirname [file tempfile _t]]`,
   which leaks the channel *and* takes the dirname of a channel handle, then deletes
   the still-open file (aborts the whole suite); `rio-gui/tests/browse.tcl:73` browses
   `/` as "the filesystem root", which has no Windows equivalent — worth noting that
   the remote-browse anchor (`rbrowse_start ""` → `/`) has no drive-letter story yet.
   `rio-gui/tests/session.tcl:19` has the same `[file dirname [file tempfile]]`
   mistake, which resolves to `.` — so on any host it builds its fixture tree in the
   **current directory**, and when the suite aborts (as it does here) it leaves
   `riosess-<pid>/` sitting in the repo root, ready to be committed by accident.
   The 4 `exec.test` failures are **not** bugs: a Windows child's stdout is CRLF and
   `rio::exec::run` captures bytes faithfully by design (D22 ethos), so the tests'
   POSIX expectations are what need relaxing. Harmless for git (git does not
   CRLF-translate its own output — `git.test` is green), but it matters for the
   planned agent run-command tool.

Also open: `rio-gui/tests/reconnect.tcl` **hangs** on Windows (>9 min, killed) —
uninvestigated.

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
