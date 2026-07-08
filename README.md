# rio

A small, cross-platform IDE, **written from scratch** in Tcl/Tk: a fast,
no-nonsense text editor with first-class git and AI-agent integration — a desktop
**GUI** today, a **terminal** frontend planned, both sharing one UI-less core.

rio aims for the **sweet spot between Windows 2000-era productivity software and a
modern IDE like Visual Studio Code**: the instant start, plain menus, and
fits-in-your-head restraint of a desktop app from the era that booted before you
blinked — carrying the VSCode ideas worth keeping (split editing, side-by-side
diffs, syntax highlighting, a propose-and-approve agent) without the Electron, the
telemetry, or the plugin bazaar.

> **North star:** *VSCode's quality, with Windows 2000-era productivity-software
> discipline, in a fraction of the code, written from scratch in Tcl/Tk.* Not a
> clone — a distillation. Small feature set, small readable codebase, fast.

## Status

**Early implementation** — real and usable, but a long way from the full IDE.
Everything below runs today:

    wish rio-gui/rio-gui.tcl [file ...]

(needs `tclsh`/Tk + `tcllib`, plus `tcltls` for the agent's HTTPS — `./rio-dev-deploy.sh`
sets it up; full install & deployment guide in [INSTALL.md](INSTALL.md).)

**What works now (GUI):**

- **Editing** — open and save with encoding and line-ending (LF/CRLF)
  **preservation** (no silent rewrites), range-based editing, undo/redo, several
  buffers as tabs, scrollbars, and optional line wrap.
- **Split editor** — show **two buffers side by side** in independent editor groups,
  each with its own tabs (`Ctrl+\` to split). **Drag tabs to reorder them within a
  group or move one across to the other group** (or use the View menu, `Ctrl+]`, or a
  tab's right-click menu). Drag the divider to resize; closing a group's last tab
  unsplits.
- **Files & git** — open a project folder and browse it in a side pane; view
  **git status and diffs** for the open repo (read-only for now). Files and git
  share one dockable, resizable side panel.
- **Compare view** — a **side-by-side diff** of two documents, original beside
  proposed, with added/removed lines coloured and aligned (VSCode-style). Compare
  the active buffer against any file from the View menu.
- **Agent chat** — a right-hand chat column wired to two providers: a
  built-in offline **echo** provider, and **Claude** over the official Anthropic API
  (bring your own API key, entered under *Settings*). The agent lives in the core
  and runs wherever it does — so over a remote core the turn and your key stay
  server-side, with the same GUI either way (see D30). It holds a streaming
  conversation and can **read your project** (listing folders, reading files and
  open buffers — shown as it works) and **propose edits**: it suggests a change or
  a new file, you review the **diff** and **Approve or Reject**, and on approval
  it applies (and, by default, saves). A **complex** edit opens live in the
  side-by-side **compare view** (toggleable) rather than inline. Reads run freely;
  every write waits for you (or opt into *Settings ▸ Auto-accept edits*).
- **Theming** — live-switchable colour themes from the View menu: the plain
  default, Solarized Dark/Light, and Plan 9 Acme. Themes are plain data files in
  `themes/`, never executed.
- **Custom keybindings** — every shortcut is one data table. Remap them in
  *Settings ▸ Keyboard Shortcuts…* (press-to-capture, applied live, no restart) or by
  hand in `~/.config/rio/keys.json`; the menus relabel themselves to match.
- **Syntax highlighting** — colour by language, harmonised with the active theme
  (each theme carries its own `syntax.*` palette, so switching recolours code live).
  The highlighters are small, self-contained files in `syntax/` with no external
  dependencies; a language is easy to add or **swap out** — drop a replacement in
  `~/.config/rio/syntax/` to override the shipped one. **(X)HTML, CSS, JavaScript,
  Perl, Tcl, and shell** ship.
- **Sessions** — reopen a project and rio brings back the files you had open and the
  active tab, plus your view preferences (theme, line-wrap, dock side, chat). The
  preferences live with the GUI; the open-file set lives with the project on the core,
  so a **remote session resumes too**. Both are plain data, never your API key.
- **Local & remote, one transport** — the GUI always talks to a core over a
  channel. **Locally there is nothing to start**: it spawns its own private core as
  a child process automatically. To edit on **another box**, run the core there
  (after a `git clone`: `./rio-server-deploy.sh` installs `tclsh` + `tcllib` +
  `tcl-tls`, then `tclsh rio-core/server.tcl 7711`, loopback by default), tunnel in
  (`ssh -L 7711:127.0.0.1:7711 host`), and attach:
  `wish rio-gui/rio-gui.tcl --connect 127.0.0.1:7711 /path/on/server` — or, from an
  already-open GUI, **File ▸ Connect to Remote Core…**. Files open and save on
  whichever box the core runs on; browse them from the file tree or the point-and-click
  Open/Save dialogs, which follow the core onto the remote disk.

**Under the hood:** all the logic lives in a **UI-less core**, and the GUI is
**always a client** to one over a channel — a pipe to a private core it spawns
locally, or a socket to a core running elsewhere (**server mode**, like
`emacs-server`). Same op calls either way; there is no separate in-process path.
Frontends are thin views — the core owns your files and broadcasts changes back.

**Still to come:** git write ops (stage/commit), an agent run-command tool (with
guardrails), the terminal frontend (below), and a polished install/packaging path.
The fuller list of candidate work lives in [ROADMAP.md](ROADMAP.md).

## The two faces, one brain

A Tk **GUI** (working) and a curses **TUI** over the same core — like `emacs` and
`emacs-nox`.

The **TUI is deferred**, deliberately. A throwaway spike proved the curses
toolkit (Ck) can carry it — rendering, editing, reflow, colour, and Unicode all
work — so the risk is retired, but building the terminal frontend is a separable,
later effort and isn't active work. Because every frontend speaks the same
language-neutral protocol, the TUI (or any third-party client, in any language)
can attach later **without touching the core**.

## Cross-platform

Linux (Debian, Alpine), the BSDs, and Windows — GUI today; the TUI when it lands.

## Learn more

- **[INSTALL.md](INSTALL.md)** — install & deployment: requirements, the deploy
  scripts, local vs. remote (server mode over SSH), the agent/Claude key, and
  troubleshooting.
- **[AGENTS.md](AGENTS.md)** — the living design & decision log (the *why* behind
  every choice). Start here if you want the full picture.
- **[ROADMAP.md](ROADMAP.md)** — possible next steps: planned features, known gaps,
  and deliberately deferred refinements.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — for programmers who want to hack on rio
  itself: toolchain setup, how it's laid out, and how to run the tests.
