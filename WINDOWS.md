# Running rio on Windows 11

A quick start for using rio day-to-day on Windows: editing notes, opening scratch
buffers for quick pasting, and viewing a logfile or two. That's the simplest slice of
rio — it needs nothing beyond Tk + tcllib — and nothing in the code blocks it on
Windows. The heavier features (git, the agent, a remote core) work here too; see
[§7](#7-beyond-notes-git-the-agent-and-remote-cores).

> **Status:** verified. rio has been run natively on Windows 11 — it launches, spawns
> its own core, edits and saves, and every test suite passed at the last run there
> (2026-09-17; see [RELEASING.md](RELEASING.md) Gate 0 for what that took and the few
> things still open). Development happens on Linux, so a Windows run always trails the
> tree by some way — §8 is how to do one. If something does break, §6 says where to
> look first.

## 1. Get rio and run the install script

Copy or clone the repository to a folder, e.g. `C:\rio`. **There is nothing to build,
and nothing to install first** — the install script handles the toolchain. From that
folder:

```
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

That one command:

1. **Installs Tcl/Tk if you don't have it.** If `tclsh` isn't found it offers to
   `winget install Magicsplat.TclTk` — one package carrying Tk *and* tcllib, exactly
   rio's dependency set. It **asks before installing anything** (answer `y`; pass
   `-Yes` to skip the prompt, or `-NoInstall` to be told how to do it by hand
   instead). §2 covers the manual route if you'd rather, or if winget isn't available.
2. **Verifies the toolchain actually loads** by running `package require` in `tclsh` —
   Tk and json are required, tls only matters for HTTPS (a hosted agent provider, or an
   `https://` extension repository) — and
   reports each by name.
3. **Sets up persistence** (§3), which decides where rio keeps your preferences and
   last session.
4. **Creates the shortcuts**: one in the Start Menu and one on the Desktop, both
   carrying rio's own icon, so you can start it like any other application. It also
   prints the launch command with the full path to `wish.exe`, for a terminal.

Pass `-NoShortcut` to skip the shortcuts, `-NoPersist` to skip step 3, or
`-VerifyOnly` to check the toolchain and change nothing. It changes nothing it
doesn't have to and is safe to re-run — do re-run it if you move the folder, since
the shortcuts point at an absolute path.

> **Then open a NEW terminal.** The Tcl installer adds `wish`/`tclsh` to your *user*
> `PATH`, but only processes started **afterwards** inherit it — including the
> terminal you just ran the script in. A terminal, editor, or VS Code window that was
> already open keeps the `PATH` it started with, so `wish` stays "not found" there no
> matter how well the install went. This is the single most common "it didn't work" on
> Windows and it is not a rio problem. The same applies to `git` after installing Git
> for Windows.

> The POSIX `install-unix.sh` / `install-server.sh` scripts are `sh` and do
> **not** run on Windows — `install-windows.ps1` is their Windows counterpart, and its
> winget step stands in for their `apt`/`apk` toolchain install.

## 2. The toolchain, if you'd rather do it by hand

Skip this if §1 worked. rio needs **Tk** and **tcllib** (for the `json`/`md5` packages
the wire protocol and sessions use); `http` ships with Tcl itself, and you do **not**
need `tcltls` unless you later use a hosted agent provider or an `https://` extension
repository. **`tkdnd`** is optional — it enables
dragging a file onto the window to open it (D86); the Magicsplat distribution below
bundles it, and rio runs fine without it (drag-to-open just does nothing).

**[Magicsplat Tcl/Tk](https://www.magicsplat.com/tcl-installer/)** is the path of least
resistance — one distribution bundling Tk *and* tcllib, which puts `wish.exe` and
`tclsh.exe` on your `PATH`. It is exactly what the script installs for you:

```
winget install --exact --id Magicsplat.TclTk --source winget
```

Or download the installer from the link above. ActiveTcl works too — add tcllib
afterwards with `teacup install tcllib`.

Either way, check it in a **new** terminal:

```
tclsh
% package require Tk
% package require json
% exit
```

Both lines should print a version, not an error. Then run `install-windows.ps1` (§1)
anyway — it will skip the install and go straight to verifying and setting up
persistence.

## 3. (Recommended) Turn on persistence

rio stores your preferences (theme, wrap, layout) and remembers which files were open,
under paths taken from `XDG_CONFIG_HOME` / `XDG_DATA_HOME`, falling back to `HOME`.

**Persistence already works without doing anything here.** Tcl on Windows always
provides `HOME` (it synthesises it from `HOMEDRIVE` + `HOMEPATH`), so with the XDG
variables unset rio falls back to `%USERPROFILE%\.config\rio` and
`%USERPROFILE%\.local\share\rio` and remembers everything across runs. Setting the
variables below only **relocates** that state to a tidier place — it does not switch
persistence on. (An earlier version of this section claimed rio "forgets your
preferences" without them; that was wrong on Windows.)

`install-windows.ps1` (§1) sets these up for you — this section is what it does, for
reference or if you'd rather do it by hand. It sets two **user environment variables**:

| Variable | Value (example) |
|----------|-----------------|
| `XDG_CONFIG_HOME` | `%USERPROFILE%\rio\config` |
| `XDG_DATA_HOME`   | `%USERPROFILE%\rio\data`   |

By hand: set them via *Settings ▸ System ▸ About ▸ Advanced system settings ▸
Environment Variables…*, or from a terminal (open a **new** terminal afterwards so
they take):

```
setx XDG_CONFIG_HOME "%USERPROFILE%\rio\config"
setx XDG_DATA_HOME   "%USERPROFILE%\rio\data"
```

## 4. Launch

The install script (§1) leaves a **rio** shortcut in the Start Menu and on the
Desktop — that is the normal way in. Right-click either one to pin it to the taskbar,
and set *Start in* to your notes folder if you'd like rio to open there.

From a terminal, or to open something specific:

```
wish C:\rio\rio-gui\rio-gui.tcl
```

- **no argument** → an empty scratch buffer, ready to type or paste into;
- **a folder** → `wish C:\rio\rio-gui\rio-gui.tcl D:\notes` opens it as the project,
  browsable in the side pane;
- **a file** → `wish C:\rio\rio-gui\rio-gui.tcl D:\notes\today.md` opens it in a tab.

If you skipped the shortcuts (`-NoShortcut`) or want another one, its target is
`"C:\path\to\wish.exe" "C:\rio\rio-gui\rio-gui.tcl"` — a shortcut to `wish.exe` with
rio's script as the argument, **not** to the `.tcl` file itself, which would follow
whatever Windows currently associates with `.tcl`.

## 5. Your daily workflow, in keys

rio ships with the **Windows editing mode** by default — the Notepad/VSCode keys you
already know:

| Task | How |
|------|-----|
| New buffer for quick pasting | **Ctrl+N**, then paste **Ctrl+V** (only **Ctrl+S** if you want to keep it) |
| Daily notes | **Ctrl+O** the file — or **Ctrl+Shift+O** the notes *folder* once, and it stays in the side pane — edit, **Ctrl+S** |
| Open a logfile | **Ctrl+O**. There's no live tail-follow yet; reopen the file to pull in new lines |
| Save As | **Ctrl+Shift+S** |
| Switch tabs | **Ctrl+Tab** / **Ctrl+Shift+Tab** |
| Reach a tab in a narrow window | The **◂ ▸** arrows page the tab bar; **View ▸ Switch to Tab…** lists them all by name; **View ▸ Multi-Line Tabs** wraps them onto rows |
| Find / replace | **Ctrl+F** / **Ctrl+H** |
| Zoom the text | **Ctrl+scroll**, or **Ctrl++** / **Ctrl+-**; **Ctrl+0** resets. Pick a font in **View ▸ Font & Zoom ▸ Font…** |

Line endings and text encoding are **preserved** on save — rio won't silently rewrite
a CRLF file to LF or change its encoding.

## 6. First-run check (this is the verification)

If a window opens and you can type, open a file, and save it — that's the milestone,
and rio is working for you on Windows.

If it doesn't:

- **`wish` not found** → almost always a **stale terminal**, not a failed install.
  Check the registry value rather than the current shell:

  ```
  powershell -c "[Environment]::GetEnvironmentVariable('Path','User')"
  ```

  If `...\Apps\Tcl86\bin` is in there, the install is fine — open a **new** terminal
  (§1/§2). Only if it's absent is the Tcl/Tk install itself the problem.
- **A `package require` error** → the Tcl/Tk install is incomplete; re-run
  `install-windows.ps1 -VerifyOnly` (§1), which reports each package by name.
- **The git pane does nothing** → same stale-`PATH` story for `git` (§7).
- **A stack trace mentioning `HOME` or a config/session path** → §3, though this
  should not happen: Tcl always provides `HOME` on Windows.

Either way, jot down exactly what broke — it's a
[RELEASING.md](RELEASING.md) Gate 0 finding, and it's how the Windows claim earns its
place in the README. The first pass of that verification is recorded in RELEASING.md
Gate 0; §8 below is the dev loop it was done with.

## 7. Beyond notes: git, the agent, and remote cores

None of these are Windows-limited — the intro calls notes the "simplest slice" only
because it needs the least. What each adds:

- **Git pane** — works once **[Git for Windows](https://git-scm.com/download/win)** is
  installed and on `PATH`. rio shells out to `git` as a plain argument vector (no
  shell), so it behaves the same as on Linux. Open a repo folder and the status/diff/
  stage/commit pane is there.
- **The agent (Claude)** — works if your Tcl build includes **`tls`** (Magicsplat's
  batteries-included distribution normally does; `install-windows.ps1` reports `tls ok`
  or `MISSING` in its verify). Then pick *Settings ▸ Agent Provider ▸ Claude (API key)*
  and enter your key in *Extensions ▸ Claude…*, the provider's own settings window.
  One Windows note: rio's `0600` lock-down of the key file is a POSIX no-op on NTFS,
  so the key file inherits your user-profile permissions rather than being explicitly
  restricted — fine for a personal machine, worth knowing.
- **HTTPS certificates (the agent, and `https://` repositories)** — rio trusts the
  **Windows certificate store** when your `tls` is **1.8 or newer on OpenSSL 3.2+**
  (`tclsh`: `package require tls` prints the version, `tls::version` the OpenSSL one).
  An older build has no way into the store, so a connection is refused as untrusted —
  set **`SSL_CERT_FILE`** to a PEM bundle (curl's `cacert.pem` is the usual one) before
  starting rio. An `https://` repository additionally needs `tls` 1.8+ to check host
  names, and says so if it's older; plain `http://` repositories need no `tls` at all.
  *Not yet verified on a Windows machine* — the store path is from tcltls's own
  documentation (INSTALL.md §1 has the full order).
- **Signed repositories** — rio checks a repository's signature by running `ssh-keygen`
  (D118), and Windows has shipped OpenSSH since Windows 10 1809. What matters is its
  **version**: signature verification needs **OpenSSH 8.0+**, and 1809's build is 7.7.
  Windows 10 1903+ and Windows 11 are fine (`ssh -V` says). On an older one, a repository
  whose key rio trusts — rio's own, out of the box — is refused rather than used
  unchecked, and says so; CAVEATS.md has the ways out, including the explicit
  *Preferences ▸ Extensions* switch. Nothing is needed for an unsigned repository.
- **Remote core (Windows client → Linux core)** — the most capable path, and the one
  with the least Windows-native risk. The GUI is a thin client; connected to a remote
  core it supports **whatever that core supports**, and since the core runs on Linux the
  agent, git, and files all run natively there. Windows 11 ships OpenSSH, so:

  ```
  ssh -L 7711:127.0.0.1:7711 you@linux-box     # in one terminal, keep it open
  wish C:\rio\rio-gui\rio-gui.tcl --connect 127.0.0.1:7711 /path/on/linux
  ```

  (with the core started on the Linux box: `tclsh rio-core/server.tcl 7711`). Or connect
  from an already-open GUI via *File ▸ Connect to Remote Core…*. See
  [INSTALL.md §4](INSTALL.md) for the full remote/server-mode picture.

**Suggested test order:** local core first (it proves the hardest Windows plumbing —
spawn, pipe, Tk, save, persistence), then git and the agent on that local core, then a
remote Linux core as a separate step. If the local-core agent ever gives trouble, a
remote core hands you full agent+git immediately with Windows as a pure client.

## 8. Hacking on rio *from* Windows

For contributors, not users. [CONTRIBUTING.md](CONTRIBUTING.md) assumes a POSIX shell;
this is the same thing in PowerShell, plus the two settings a Windows clone needs.

**Set up the clone.** Windows cannot store the POSIX executable bit, so a clone that
inherited `core.filemode = true` reports every executable file as permanently modified
and a `git commit -a` would strip the bit for the Linux hosts:

```
git config core.filemode false
```

Line endings need no setup — [.gitattributes](.gitattributes) pins the whole tree to
LF (and `*.ps1` to CRLF) regardless of your `core.autocrlf`.

**Run the suites.** They all run natively; none needs a display server:

```
tclsh rio-core\tests\all.tcl              # core (tcltest)
tclsh syntax\tests\all.tcl                # highlighters (pure Tcl)
tclsh plugins\lib\tests\all.tcl           # shared plugin lib (json + HTTP transport)
tclsh extensions\claude\tests\all.tcl     # the Claude provider extension
tclsh extensions\openai\tests\all.tcl     # the OpenAI-compatible provider extension
wish  rio-gui\tests\smoke.tcl             # GUI, window withdrawn
wish  rio-gui\tests\pipe.tcl              # the spawned-core pipe transport
```

The `rio-gui\tests\*.tcl` suites are each run the same way; `sandbox.tcl` is a helper
the others source, not a suite.

**Put `openssl` on the PATH before you trust a core run.** `rio-core\tests\tls.test`
mints its own certificates with the `openssl` CLI and serves them over loopback — that
is how D109–D111 (https repositories, refusing what doesn't verify, accepting one
anyway) are actually tested. Without the CLI the whole loopback half **skips**, and
tcltest reports that only as a count at the very end, so a run missing 19 tests still
prints `0 failed`. Git for Windows already ships OpenSSL 3.5.7; it just isn't on the
PATH, because only `Git\cmd` is:

```
$env:Path += ';C:\Program Files\Git\usr\bin'
```

With it, `rio-core` skips just the three `unix`-constrained permission tests. Check the
skip count, not only the failure count.

**"Test files exiting with errors" on a green run is noise here.** A core run ends by
naming `http.test`, `sig.test` and `tls.test` that way even when every test in them
passed. All three pull in tcllib's `sha256`, which tries to build its critcl accelerator
on first use, finds no MSVC `cl` on a box without Visual Studio, and writes the whole
failed compile to **stderr** — which is all tcltest needs to flag the file. The pure-Tcl
implementation it falls back to is correct: `rio::http::_sha256` agrees with `openssl
dgst -sha256` byte for byte. Run any of the three on its own (`tclsh rio-core\tests\all.tcl
-file sig.test`) and you get its real tally, with no such line.

Note the GUI form: CONTRIBUTING shows `RIO_GUI_HEADLESS=1 wish …`, which is POSIX
shell syntax that PowerShell cannot parse. **No prefix is needed** — the GUI test
scripts set `RIO_GUI_HEADLESS` themselves. To set it anyway, PowerShell wants
`$env:RIO_GUI_HEADLESS = 1` as its own statement first.

**Capturing a GUI suite's output — PowerShell's `>` does not work.** `wish.exe` is a
GUI-subsystem binary with no console attached, and **PowerShell's redirection operator
captures nothing from it** — `wish rio-gui\tests\smoke.tcl > out.txt` leaves you a
**zero-byte file** and no error. Two things do work, because both hand the process a
real file handle:

```
cmd /c "wish rio-gui\tests\smoke.tcl > out.txt 2>&1"
```

```
# and, for scripting a whole sweep with a per-suite timeout:
$p = Start-Process wish -ArgumentList "rio-gui\tests\smoke.tcl" -NoNewWindow -PassThru `
     -RedirectStandardOutput out.txt -RedirectStandardError err.txt
if (-not $p.WaitForExit(180000)) { $p.Kill() }
```

Run a suite with no redirection at all and you see nothing either way, so a green run
and a broken one look identical. Capture first, then read the result.

**Seeing failures — read this before you debug anything.** Being GUI-subsystem has a
second consequence: an *uncaught* error at the top level of a script does not go to
stderr, it opens a **modal "Error in startup script" dialog and blocks until someone
clicks OK**. Redirecting stderr captures nothing. So an aborting suite looks like
output that simply stops early for no reason, and an *unattended* run appears to
**hang** rather than fail — which is also why there is no Windows CI story yet.

When a suite ends without its `ALL CHECKS PASSED` line, re-run it inside a catch to
get the error and the stack on stdout instead of in a dialog:

```
# runtest.tcl
set t [file normalize [lindex $argv 0]] ; set argv {}
if {[catch {uplevel #0 [list source $t]} err]} {
    puts "*** $err" ; puts $::errorInfo ; exit 99
}
```

```
wish runtest.tcl rio-gui\tests\highlight.tcl
```

**Where Windows stands.** At the last full Windows run — **2026-09-23, commit
`aa7afd1`** (D114–D131) — everything was green, with nothing hanging and nothing skipped
beyond the three `unix`-constrained permission tests:

| Suite | Result |
|---|---|
| `rio-core` | 860 passed / 0 failed (3 skipped: `unix` constraint) |
| `syntax` | 536 / 536 |
| `plugins/lib` | 20 / 20 |
| `extensions/claude` | 55 / 55 |
| `extensions/openai` | 115 / 115 |
| `rio-gui` | 2234 checks / 0 failed, across 28 suites |

`tls.test` ran its loopback half in full (55 / 55, nothing skipped) with `openssl` on the
PATH, so D109–D111 were genuinely exercised rather than counted as green while skipped.

The suites grow with the tree, so treat this as a **dated record, not today's count**:
a fresh run should give bigger numbers, and what matters is that the failure column is
still zero and the skip column still reads three. The findings behind the run — and the
handful of things still open — are in [RELEASING.md](RELEASING.md) Gate 0.

**Writing a GUI test that measures widget geometry.** A headless run withdraws the
window — but X11 assigns a toplevel real geometry whether or not it is ever mapped,
and **Windows does not**. Left withdrawn from boot, `winfo width .` there stays at a
trivial 120x1 and every child collapses with it (the tab strip measured 47px), so any
check asking whether something *fits* its pane silently reads the wrong answer: a
scrollbar that should have auto-hidden stays, every tab past the first "overflows".
`rio-gui.tcl`'s headless branch therefore **maps the window once, off-screen, before
withdrawing it** — the sizes survive the withdraw. Nothing extra is needed in a test,
but if a geometry-dependent check ever disagrees across platforms, this is the first
thing to suspect; guard genuinely WM-dependent checks the way
`rio-gui/tests/gutter_select.tcl` guards its pixel-mapping one.

**One rule to keep it that way: every script rio runs sets the encoding first.** Tcl 8.6
decodes a script with the *system* encoding, which is cp1252 on Windows, so any file run
directly — `rio-gui.tcl`, `rio-core/server.tcl`, each `rio-gui/tests/*.tcl`, each suite
runner, **and each `.test`** — opens with the four-line UTF-8 guard, which re-reads the
file as UTF-8. A file without it compares rio's correct output against its own mojibake
and fails confusingly.

**A `.test` used to be treated as the exception; it is not one.** This section said the
guard "works by re-sourcing `[info script]`, which a `.test` cannot do", and argued it
from what the *parent* can configure — a different question. tcltest runs each `.test` as
a **child process's main script**, which is precisely the case D54's guard is written for,
and the guard works there unchanged. Every `.test` carries it as of 2026-09-23, and
`rio-core/tests/encoding.test` holds every runnable script to it — so the rule has a guard
now rather than a reminder. The `\u` escapes in `http.test` and `fs.test` stay because
they name a codepoint outright next to a hard-coded hash, not because a literal would
break; the `\x` **byte** inputs in `fs.test` stay because they are bytes, which is a
different thing entirely.

**You do not need this box to catch that class.** On the Linux side, `LANG=C LC_ALL=C
tclsh` gives `encoding system` = `iso8859-1`, which mangles a UTF-8 literal the same way
cp1252 does — so `LANG=C LC_ALL=C tclsh rio-core/tests/all.tcl` reproduces a Windows-only
decoding fault before it ever reaches Windows. That the 2026-09-23 run found two such
literals, both written on Linux where the system encoding hides the mistake, is what
prompted the guard.

A literal also survives review whenever the *same* literal sits on both sides of the
comparison, because the mojibake cancels; it fails only once one side is computed
independently — a hard-coded `sha256`, or output decoded from explicit byte escapes.
Several such latent comparisons live in `wire.test`, `plugins/lib/tests/json.test` and
both extensions' tests; the guard makes them test what they claim to rather than testing
mangled input. Non-ASCII in *comments* and test descriptions was never at risk; nothing
compares those.
