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

rio claims Linux, the BSDs, and **Windows** ([README](README.md)). You cannot honestly
ship a cross-platform claim you haven't run — so this gate was about running it.

*(Both boxes are now ticked; the record below is what it found. The BSDs stay an
untested design target and the README says so.)*

- [x] Launch `wish rio-gui/rio-gui.tcl` on Windows and record what breaks.
      **Done 2026-09-02**, Windows 11 Pro 22631, Magicsplat Tcl/Tk 8.6.16, Git for
      Windows 2.55.0.5. **rio launches, spawns its private core over the pipe, and
      edits.** Findings below.
- [x] Then either fix Windows to a usable state, or **narrow the README claim** to
      the platforms that actually work and mark Windows "in progress." An honest
      smaller claim beats a broken bigger one.
      **Fixed, so the claim stands** — and now earns it: every suite passes on
      Windows and the findings below are closed. The README's *Cross-platform*
      section says which platforms have actually been run, rather than leaving the
      reader to assume all three were.

**Gate 0 is complete.** The remaining Windows items are listed under *Still open*
below; none of them blocks the platform claim.

### Gate 0 findings — first Windows run (2026-09-02/03)

Windows 11 Pro 22631, Magicsplat Tcl/Tk 8.6.16, Git for Windows 2.55.0.5.
**Every suite is now green on Windows**, with nothing hanging. Re-verified 2026-09-09
against `697acd2`, which brought D56–D87 (providers as extensions, the agent's
run-command tool and its allow-list, the tab strip, the files tree, drag-to-open):

| Suite | Result |
|-------|--------|
| `rio-core` | 478 total, **475 passed, 0 failed**, 3 skipped (the `unix`-constrained permission tests) |
| `syntax` | **532 / 532** |
| `plugins/lib` | **9 / 9** |
| `extensions/claude` | **30 / 30** |
| `extensions/openai` | **29 / 29** |
| `rio-gui` | **1218 checks, 0 failed** across all 21 suites |

The earlier note that `reconnect.tcl` hangs was already superseded by finding 7 below
(it was the test's own teardown, fixed); it passes.

What was **not** a problem, recorded so nobody re-investigates it: the spawned-core
child + pipe transport (`pipe.tcl` green — `auto_execok tclsh`, the `wish`→`tclsh`
name fallback, `open |… r+`, and the `-translation lf -encoding utf-8` channel all
behave); path handling; Tk theming and fonts; persistence (Tcl synthesises `HOME`
from `HOMEDRIVE`+`HOMEPATH`, so the XDG fallback resolves — WINDOWS.md §3).

#### 1. Tcl 8.6 decodes scripts with the system encoding — **fixed**

Tcl 8.6 reads a script file in the **system** encoding (cp1252 on a Western Windows
install), not UTF-8, so every non-ASCII literal arrived mojibake and **D27's whole
monochrome-Unicode iconography rendered as garbage**: the title bar read
`rio â€" untitled`, the file pane offered `Open a folderâ€¦`, and `●` `⟳` `▸` `✓` `×`
`·` `↑↓` `▶` `⎇` were all broken. 192 non-comment lines across the tree carry such
literals, 125 of them in `rio-gui.tcl`. This was the one **user-visible** defect.

Fixed with a four-line guard at each **entry point** — `rio-gui/rio-gui.tcl`,
`rio-core/server.tcl`, and every `rio-gui/tests/*.tcl`:

```tcl
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
```

Setting the system encoding fixes every file sourced *below* it; the re-read fixes
the entry file's own literals, which were decoded before line 1 ran. It is the first
executable statement, so re-sourcing repeats no work, and it is a **no-op** where the
system encoding is already UTF-8 (Linux, the BSDs, and Tcl 9 everywhere — Tcl 9
defaults `source` to UTF-8, which is what makes this a 8.6-shaped problem).

`encoding system utf-8` was safe to set globally because rio never leans on the
default: `rio::fs::read`/`write` open `rb`/`wb` and call `encoding convertfrom/to`
explicitly (D22), and every config reader and the wire channel pin `-encoding utf-8`.

*Corollary, worth knowing:* a `.test`/`.tcl` file's own non-ASCII **expected values**
are subject to the same decoding. `rio-core/tests/fs.test`'s `fs-read-multibyte` was
comparing rio's correctly-decoded result against its own mis-decoded literal — rio was
right and the test was wrong. Expected values with non-ASCII are now written as `\u`
escapes, matching how that test already wrote its `\x` input bytes.

#### 2. A leaked channel when a parse throws between `open` and `close` — **fixed**

A real rio bug, invisible on POSIX. Four sites in `rio-gui.tcl` read config as
`open … ; parse ; close` inside a `catch`; a throwing parse skipped the `close` and
leaked the channel. On Windows an open handle makes a file **undeletable**, so after
rio read **one** corrupt `prefs.json` or `keys.json` — exactly the case each has a
passing "corrupt file tolerated" test for — that file stayed locked for the life of
the process and could never be rewritten or reset.

Replaced with one `slurp_utf8` helper whose `close` sits in a `finally`. Fixes
`prefs_load`, `sources_load`, `ledger_load` and `keymap_resolve` at once, and was the
cause of 3 `keymap.tcl` failures and the `session.tcl` abort.

#### 3. `glob *` matches dotfiles on Windows — **fixed**

`rio::fs::listdir` globbed `{* .*}` and concatenated. The patterns are disjoint on
POSIX; on Windows `glob *` matches dotfiles too, so **every dotfile was listed twice**
— the file pane showing `.git`, `.gitignore`, `.gitattributes` doubled, and
`project.search` walking them twice. One word: `lsort -dictionary -unique`.

#### 4. POSIX-only assumptions in test helpers — **fixed**

- `stdio.test` redirected to `/dev/null`; on Windows the bit bucket is `NUL` and the
  open failed before the core ever started (3 failures).
- `highlight.tcl` and `session.tcl` took `[file dirname [file tempfile _t]]` — the
  dirname of a **channel handle**, which is `"."`. That leaked the channel (so the
  delete failed on Windows and aborted the suite) *and* silently built fixture trees
  in the **current directory**, leaving `riosess-<pid>/` in the repo root whenever a
  suite died before cleanup. Now gitignored as well as fixed.
- `smoke.tcl` asserted the API-key file is `0600` via `file attributes -permissions`,
  which does not exist on Windows and **raises** rather than returning — aborting the
  entire suite at check 224 of 371 rather than failing one check. `rio-core`'s
  `secret.test`/`workspace.test` already gate the same assertion with tcltest's `unix`
  constraint; `smoke.tcl` now gates it by hand.
- `browse.tcl` browsed `/` as "the filesystem root". On Windows `/` is not even an
  absolute path (`file pathtype` calls it `volumerelative`), so the core refused to
  list it. It now asks the platform via `file normalize /`.
- `exec.test`'s four failures were **not** bugs: the fixture child is `tclsh`, whose
  stdout defaults to the platform convention (CRLF on Windows), and `rio::exec::run`
  captures a child's bytes faithfully by design (D22). The tests were asserting the
  platform's stdio convention rather than rio's capture fidelity; the child's
  translation is now pinned to `lf` so they mean the same thing everywhere. Harmless
  for git (git does not CRLF-translate its own output — `git.test` was always green),
  but it matters for the planned agent run-command tool.

#### 5. `rbrowse_rows_for` assumed `/` is the only root — **fixed**

The "am I at a filesystem root?" test was `$abs ne "/"`. A Windows root is `C:/`, so
the browser offered a `../` row there that navigated back to the same directory. Now
`[file dirname $abs] ne $abs`, which is platform-neutral and — since `$abs` is the
**core's** normalized path — stays correct against a remote core on another platform.

#### 6. The client judged the core's paths by its own rules — **fixed**

Found on 2026-09-03 during the first **remote** run (Windows GUI → Linux core on
vps01, over the SSH tunnel), and confirmed against that live core: `fs.list /`
returns `/` with `bin boot dev etc home lib`, so browsing works — but the GUI was
deciding what a *core* path means using **client** rules.

`file pathtype` is the trap. On the Windows client, the Linux core's `/home/jka` is
**`volumerelative`**, not `absolute`. Two sites asked exactly that:

- the browser's name/Location field treated any typed absolute remote path as
  *relative* and joined it onto the current directory, so typing `/etc/hosts`
  silently produced `/home/jka/etc/hosts`;
- `rbrowse_start` never recognised a remote seed as absolute, so Save-As on a remote
  file opened at the project root instead of that file's own folder.

Both now use one `core_path_absolute` helper that judges by **shape** — a leading `/`
(POSIX, and UNC as `//`) or an `X:` drive prefix — which reads correctly for either
core from either client, and is deliberately not `file normalize`: on a Windows
client that rewrites `/home/jka` to `C:/home/jka`. Twelve cases checked, including
the `C:notes.txt` drive-*relative* form that must stay non-absolute.

`on_fs_changed` had the third instance, comparing `[file normalize …]` of two paths
that both came **from** the core. It matched only because both operands were mangled
identically; it now compares the core's strings directly.

Not affected, and worth knowing: `file dirname` and `file join` *are* safe on POSIX
paths from a Windows client (`dirname /` → `/`, so the D54-era root fix holds in
remote mode too). It is specifically `pathtype` and `normalize` that lie.

#### 7. `reconnect.tcl` hung in its CLEANUP, not the reconnect path — **fixed**

The suite ran all 16 checks green and then never reached its verdict line, which is
why it read as a hang in the reconnect code. It was the teardown:

```tcl
catch {exec kill $bpid}     ;# `kill` is not a Windows command -- caught, so B lived
catch {close $coreB}        ;# blocks until the child exits -- forever
```

`close` on a command-pipeline channel waits for the child, and it is a *blocking*
close that does not even yield to the event loop (a probe written to race it with an
`after` timer hung too). With the kill silently swallowed, daemon B kept listening and
the close waited on it indefinitely. Now `taskkill /PID $bpid /F` on Windows, `kill`
elsewhere. **`reconnect.tcl` passes.** Nothing was wrong with reconnect itself.

#### 8. `transport.test` deadlocked its own event loop — **fixed** (2026-09-09)

The shared-transport suite **hung indefinitely** (killed after ten minutes) at
`transport-stream-200`, despite that test arming a 5s watchdog — the watchdog is armed
*after* `stream` returns, so it could never fire. The transport itself is fine on
Windows: driven from a probe it delivered its chunk and a 200 in 165ms.

The fault was the test's own one-shot HTTP server, which shares its process — and so
its single event loop — with the async client it serves. Its `gets` was **blocking**,
and `::http` writes the request *from that same loop*: the server sat waiting for
headers only the starved loop could send. Instrumenting it showed the server reading
`POST /v1/messages HTTP/1.0` and then hanging on the next line, i.e. a genuinely
partial request. This is **latent on Linux**, where a loopback connect completes
promptly enough that the whole request is usually buffered before the accept callback
first runs — the ordering was never guaranteed there either. The server now reads via
fileevents; the suite went from a ten-minute hang to 9/9 in two seconds.

#### 9. A killed child's exit code is 1 on Windows, not -1 — **test corrected**

`exec-start-timeout` asserted `exitcode -1` for a command killed by its watchdog. That
is unix's `CHILDKILLED`; Windows has no signals, so `taskkill /F` leaves an ordinary
exit 1. The implementation is right on both — `timedout` was correctly 1 — and nothing
reads the exit code in that case (`format_exec` checks `timedout` first). The test now
asserts `timedout` plus *non-zero*, and the platform difference is logged in
[CAVEATS.md](CAVEATS.md), as `exec.tcl`'s own comment asks.

#### Verified against a real remote core (2026-09-03)

Windows GUI → the live `rio-core` on **vps01.jkdata.de** over an SSH tunnel, i.e. a
genuine cross-platform pairing rather than a local daemon standing in for one. 21
checks, all passing: the transport is marked remote and reports the endpoint; the
core's root is POSIX `/`; the browser lists `/` with no bogus `../` row and `/home`
with a correct one pointing at `/`; a remote seed opens in its own directory (finding
6's fix, proven against the real core); a file created under `/tmp` on vps01 opens,
edits, and **saves back to the core's disk byte-for-byte**; a second remote file opens
as its own tab and an unedited save is byte-faithful; and `git.status` answers over the
socket with a branch. Scratch files and buffers were removed afterwards.

This is the cross-platform case the in-repo `remote.tcl` cannot cover (it uses a local
daemon), so it stays a manual check — but the path is now exercised, not assumed.
Re-run after D55 with all 22 green, including against a core older than that change.

One behaviour confirmed by accident and worth recording: with the SSH tunnel up but
**no core listening behind it**, `ssh` accepts the local connection and the far end
closes the channel immediately. rio handles this correctly — `hello_core`'s bounded
greeting notices and reports "Connected to …, but no rio core answered … most likely a
stale SSH tunnel", rather than sitting on a blank window. On Windows that report is a
modal dialog (see the note above), so a *scripted* run still looks like a hang even
though the interactive behaviour is right.

### Still open
- ~~**`rbrowse_start` still falls back to a literal `"/"`**~~ — **fixed** (D55).
  `session.hello` now reports `fsroot`, the root of the core's *own* filesystem, and
  the GUI records it per attachment instead of guessing. Verified three ways: a local
  Windows core reports `C:/` and the browser opens there and lists it; a stubbed
  greeting without the field leaves the client on its default; and — the one that
  matters — the **live vps01 core, which predates the field, was confirmed not to send
  it** and the Windows GUI degraded to `/` and browsed correctly anyway. So the
  additive-not-a-protocol-bump claim is tested against a genuine older peer, not only
  a mock. **Re-checked 2026-09-09, now against the updated vps01 core**, closing the
  other half: it *does* send `fsroot: /`, the Windows client reads that as absolute
  (its own `file pathtype /` says `volumerelative`, which is exactly the trap D55
  exists to avoid), and `fs.list /` returns the Linux root's 20 entries. Both a peer
  that sends the field and one that doesn't are now verified live, not stubbed.
- ~~**`smoke.tcl`'s `pane: scrollbar hidden when list fits` is flaky**~~ — **fixed, and
  it was never a flake.** I misdiagnosed it as timing: it was the headless window's
  *geometry*. X11 gives a toplevel real geometry whether or not it is ever mapped;
  Windows does not, so a window withdrawn from boot stayed 120x1 and every child
  collapsed with it — a pane one pixel high never "fits" a two-row list, and the strip
  measured 47px so every tab past the first overflowed (`tabs.tcl`'s two `few:` checks
  failed the same way, and `gutter_select.tcl` silently *skipped* its pixel-mapping
  check). `rio-gui.tcl`'s headless branch now maps the window once, off-screen, before
  withdrawing it; the sizes survive. All three suites pass and the skipped check runs.
- **`secret.tcl`'s `0600`/`0700` lock-down is a no-op on NTFS.** The calls are
  `catch`-wrapped, so nothing breaks, but the Claude API key file inherits
  user-profile permissions rather than being explicitly restricted (WINDOWS.md §7).
- **`wish.exe` reports an uncaught top-level error in a modal dialog**, not on stderr —
  and blocks until someone clicks OK. A suite that dies therefore looks like output
  that simply stops, and an unattended run *hangs* rather than failing. This is the
  single biggest obstacle to a Windows CI run; WINDOWS.md §8 carries the
  error-trapping runner that works around it.

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
      exactly which rio they're running. *(Interim: **Help ▸ About rio** already shows the
      build id via `git describe --tags --always` — the short commit today, the tag
      automatically once this is done. AGENTS.md D76.)*

## Gate 3 — First run & intake

- [ ] Verify graceful failure when `tcllib` / `tcltls` is missing — a clear "install
      X" message, not a stack trace. Cross-check against [INSTALL.md](INSTALL.md).
- [ ] Add an issue-reporting path (a link in the README) and a short "alpha status"
      note: what's rough, save often, and that there is **no crash recovery yet**.

## Named, and deferred on purpose

- **Crash / autosave recovery** is absent — a hard kill loses unsaved buffers. (A
  *clean* quit is guarded: `do_quit` prompts to save every modified buffer.)
  Acceptable for an alpha as long as it's stated plainly in the release notes.
