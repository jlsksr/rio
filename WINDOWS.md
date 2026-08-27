# Running rio on Windows 11

A quick start for using rio day-to-day on Windows: editing notes, opening scratch
buffers for quick pasting, and viewing a logfile or two. That's the simplest slice of
rio — it needs nothing beyond Tk + tcllib — and nothing in the code blocks it on
Windows. The heavier features (git, the agent, a remote core) work here too; see
[§7](#7-beyond-notes-git-the-agent-and-remote-cores).

> **Honest status:** rio's launch and editing paths are cross-platform Tcl/Tk, but
> rio has not yet been exercised on Windows in anger (see [RELEASING.md](RELEASING.md)
> Gate 0). Treat your first day of use as the verification, and note anything that
> breaks — §6 says what the likely culprits are.

## 1. Install Tcl/Tk (with tcllib)

rio needs **Tk** and **tcllib** (for the `json`/`md5` packages the wire protocol and
sessions use). `http` ships with Tcl itself. You do **not** need `tcltls` unless you
later use the Claude agent.

The path of least resistance is **[Magicsplat Tcl/Tk](https://www.magicsplat.com/tcl-installer/)**
— a single distribution that bundles Tk **and** tcllib and puts `wish.exe` and
`tclsh.exe` on your `PATH`. Install it with **winget** in one line:

```
winget install --exact --id Magicsplat.TclTk --source winget
```

(Or download the installer from the link above; ActiveTcl works too — add tcllib
afterwards with `teacup install tcllib`.) You don't have to run this yourself: if Tcl
is missing, `rio-dev-deploy.ps1` (§2) offers to run exactly this winget install for
you, after asking.

Verify the toolchain in a terminal:

```
tclsh
% package require Tk
% package require json
% exit
```

Both `package require` lines should print a version, not an error.

## 2. Get rio

Copy or clone the repository to a folder, e.g. `C:\rio`. There is nothing to build.

Then run the Windows deploy script from that folder:

```
powershell -ExecutionPolicy Bypass -File .\rio-dev-deploy.ps1
```

It **verifies** the toolchain actually loads (Tk + json; tls only if you'll use the
agent), sets up **persistence** (§3) for you, and prints the launch command. Add
`-Shortcut` to also drop a "rio" shortcut on your Desktop, or `-VerifyOnly` to just
check the toolchain. It changes nothing it doesn't have to and is safe to re-run.

> The POSIX `rio-dev-deploy.sh` / `rio-server-deploy.sh` scripts are `sh` and do
> **not** run on Windows — `rio-dev-deploy.ps1` is their Windows counterpart, and the
> Magicsplat installer in §1 replaces the `apt`/`apk` toolchain install (Windows has
> no package manager for Tcl, so that one step stays manual).

## 3. (Recommended) Turn on persistence

rio stores your preferences (theme, wrap, layout) and remembers which files were open,
under paths taken from `XDG_CONFIG_HOME` / `XDG_DATA_HOME`, falling back to `HOME`.
On Windows those are often unset — in which case **rio still launches and edits
perfectly, but forgets your preferences and last session between runs.**

`rio-dev-deploy.ps1` (§2) sets these up for you — this section is what it does, for
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
| Find / replace | **Ctrl+F** / **Ctrl+H** |

Line endings and text encoding are **preserved** on save — rio won't silently rewrite
a CRLF file to LF or change its encoding.

## 6. First-run check (this is the verification)

If a window opens and you can type, open a file, and save it — that's the milestone,
and rio is working for you on Windows.

If it doesn't:

- **`wish` not found, or a `package require` error** → the Tcl/Tk install (§1): make
  sure Magicsplat finished and a **new** terminal sees `wish` on `PATH`.
- **A stack trace mentioning `HOME` or a config/session path** → set the environment
  variables in §3 and relaunch.

Either way, jot down exactly what broke — it's the first real
[RELEASING.md](RELEASING.md) Gate 0 finding, and it's how the Windows claim earns its
place in the README.

## 7. Beyond notes: git, the agent, and remote cores

None of these are Windows-limited — the intro calls notes the "simplest slice" only
because it needs the least. What each adds:

- **Git pane** — works once **[Git for Windows](https://git-scm.com/download/win)** is
  installed and on `PATH`. rio shells out to `git` as a plain argument vector (no
  shell), so it behaves the same as on Linux. Open a repo folder and the status/diff/
  stage/commit pane is there.
- **The agent (Claude)** — works if your Tcl build includes **`tls`** (Magicsplat's
  batteries-included distribution normally does; `rio-dev-deploy.ps1` reports `tls ok`
  or `MISSING` in its verify). Then pick *Settings ▸ Agent: Claude (API key)* and enter
  your key under *Settings ▸ Claude API Key…*. One Windows note: rio's `0600` lock-down
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
