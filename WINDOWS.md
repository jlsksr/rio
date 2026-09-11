# Running rio on Windows 11

A quick start for using rio day-to-day on Windows: editing notes, opening scratch
buffers for quick pasting, and viewing a logfile or two. That's the simplest slice of
rio — it needs nothing beyond Tk + tcllib — and nothing in the code blocks it on
Windows. The heavier features (git, the agent, a remote core) work here too; see
[§7](#7-beyond-notes-git-the-agent-and-remote-cores).

> **Status:** verified. rio has now been run natively on Windows 11 — it launches,
> spawns its own core, edits and saves, and every test suite passes (see
> [RELEASING.md](RELEASING.md) Gate 0 for what that took and the few things still
> open). If something does break, §6 says where to look first.

## 1. Get rio and run the deploy script

Copy or clone the repository to a folder, e.g. `C:\rio`. **There is nothing to build,
and nothing to install first** — the deploy script handles the toolchain. From that
folder:

```
powershell -ExecutionPolicy Bypass -File .\rio-dev-deploy.ps1
```

That one command:

1. **Installs Tcl/Tk if you don't have it.** If `tclsh` isn't found it offers to
   `winget install Magicsplat.TclTk` — one package carrying Tk *and* tcllib, exactly
   rio's dependency set. It **asks before installing anything** (answer `y`; pass
   `-Yes` to skip the prompt, or `-NoInstall` to be told how to do it by hand
   instead). §2 covers the manual route if you'd rather, or if winget isn't available.
2. **Verifies the toolchain actually loads** by running `package require` in `tclsh` —
   Tk and json are required, tls only matters if you'll use the Claude agent — and
   reports each by name.
3. **Sets up persistence** (§3) so rio remembers your preferences and last session.
4. **Prints the launch command**, with the full path to `wish.exe`.

Add `-Shortcut` to also drop a "rio" shortcut on your Desktop, or `-VerifyOnly` to
check the toolchain and change nothing. It changes nothing it doesn't have to and is
safe to re-run.

> **Then open a NEW terminal.** The Tcl installer adds `wish`/`tclsh` to your *user*
> `PATH`, but only processes started **afterwards** inherit it — including the
> terminal you just ran the script in. A terminal, editor, or VS Code window that was
> already open keeps the `PATH` it started with, so `wish` stays "not found" there no
> matter how well the install went. This is the single most common "it didn't work" on
> Windows and it is not a rio problem. The same applies to `git` after installing Git
> for Windows.

> The POSIX `rio-dev-deploy.sh` / `rio-server-deploy.sh` scripts are `sh` and do
> **not** run on Windows — `rio-dev-deploy.ps1` is their Windows counterpart, and its
> winget step stands in for their `apt`/`apk` toolchain install.

## 2. The toolchain, if you'd rather do it by hand

Skip this if §1 worked. rio needs **Tk** and **tcllib** (for the `json`/`md5` packages
the wire protocol and sessions use); `http` ships with Tcl itself, and you do **not**
need `tcltls` unless you later use the Claude agent. **`tkdnd`** is optional — it enables
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

Both lines should print a version, not an error. Then run `rio-dev-deploy.ps1` (§1)
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

`rio-dev-deploy.ps1` (§1) sets these up for you — this section is what it does, for
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

```
wish C:\rio\rio-gui\rio-gui.tcl
```

- **no argument** → an empty scratch buffer, ready to type or paste into;
- **a folder** → `wish C:\rio\rio-gui\rio-gui.tcl D:\notes` opens it as the project,
  browsable in the side pane;
- **a file** → `wish C:\rio\rio-gui\rio-gui.tcl D:\notes\today.md` opens it in a tab.

**Pin it:** make a desktop/taskbar shortcut whose target is
`"C:\path\to\wish.exe" "C:\rio\rio-gui\rio-gui.tcl"`, and set *Start in* to your notes
folder. Now rio is one click away.

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
  `rio-dev-deploy.ps1 -VerifyOnly` (§1), which reports each package by name.
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
  batteries-included distribution normally does; `rio-dev-deploy.ps1` reports `tls ok`
  or `MISSING` in its verify). Then pick *Settings ▸ Agent Provider ▸ Claude (API key)*
  and enter your key under *Preferences ▸ Agent*. One Windows note: rio's `0600` lock-down
  of the key file is a POSIX no-op on NTFS, so the key file inherits your user-profile
  permissions rather than being explicitly restricted — fine for a personal machine,
  worth knowing.
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

**Where Windows stands today.** Everything is green, with nothing hanging and nothing
skipped beyond the three `unix`-constrained permission tests:

| Suite | Result |
|---|---|
| `rio-core` | 475 passed / 0 failed (3 skipped: `unix` constraint) |
| `syntax` | 532 / 532 |
| `plugins/lib` | 9 / 9 |
| `extensions/claude` | 30 / 30 |
| `extensions/openai` | 29 / 29 |
| `rio-gui` | 1218 checks / 0 failed, across 21 suites |

The findings behind that — and the handful of things still open — are in
[RELEASING.md](RELEASING.md) Gate 0.

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

**One rule to keep it that way: every entry point sets the encoding first.** Tcl 8.6
decodes a script with the *system* encoding, which is cp1252 on Windows, so any file
run directly — `rio-gui.tcl`, `rio-core/server.tcl`, each `rio-gui/tests/*.tcl` — opens
with the four-line UTF-8 guard those files carry. A new test file without it will
compare rio's correct output against its own mojibake expectations and fail confusingly.
Non-ASCII **expected values** in a `.test` are safer written as `\u` escapes regardless.
