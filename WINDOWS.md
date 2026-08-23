# Running rio on Windows 11

A quick start for using rio day-to-day on Windows: editing notes, opening scratch
buffers for quick pasting, and viewing a logfile or two. It's the simplest slice of
rio — no agent, no git, no remote core — and nothing in the code blocks it on Windows.

> **Honest status:** rio's launch and editing paths are cross-platform Tcl/Tk, but
> rio has not yet been exercised on Windows in anger (see [RELEASING.md](RELEASING.md)
> Gate 0). Treat your first day of use as the verification, and note anything that
> breaks — §6 says what the likely culprits are.

## 1. Install Tcl/Tk (with tcllib)

rio needs **Tk** and **tcllib** (for the `json`/`md5` packages the wire protocol and
sessions use). `http` ships with Tcl itself. You do **not** need `tcltls` unless you
later use the Claude agent.

The path of least resistance is **[Magicsplat Tcl/Tk](https://www.magicsplat.com/tcl-installer/)**
— a single Windows installer that bundles Tk **and** tcllib and puts `wish.exe` and
`tclsh.exe` on your `PATH`. (ActiveTcl works too; add tcllib afterwards with
`teacup install tcllib`.)

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

The `rio-dev-deploy.sh` / `rio-server-deploy.sh` scripts are POSIX `sh` and do **not**
run on Windows — the Magicsplat installer in §1 is their Windows replacement.

## 3. (Recommended) Turn on persistence

rio stores your preferences (theme, wrap, layout) and remembers which files were open,
under paths taken from `XDG_CONFIG_HOME` / `XDG_DATA_HOME`, falling back to `HOME`.
On Windows those are often unset — in which case **rio still launches and edits
perfectly, but forgets your preferences and last session between runs.**

To keep them, set two **user environment variables** once:

| Variable | Value (example) |
|----------|-----------------|
| `XDG_CONFIG_HOME` | `%USERPROFILE%\rio\config` |
| `XDG_DATA_HOME`   | `%USERPROFILE%\rio\data`   |

Set them via *Settings ▸ System ▸ About ▸ Advanced system settings ▸ Environment
Variables…*, or from a terminal (open a **new** terminal afterwards so they take):

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
