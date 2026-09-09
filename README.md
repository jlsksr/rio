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
sets it up, or `rio-dev-deploy.ps1` on Windows; full install & deployment guide in
[INSTALL.md](INSTALL.md).)

**What works now (GUI):**

- **Editing** — open and save with encoding and line-ending (LF/CRLF)
  **preservation** (no silent rewrites), range-based editing, undo/redo, several
  buffers as tabs, scrollbars, a line-number gutter (with an optional relative mode),
  current-line highlighting, a cursor-position (line/column) readout in the status bar,
  and optional line wrap.
- **Find & Replace** — a find bar (`Ctrl+F`, `Ctrl+H` for the replace row) with
  live match highlighting and a match count, `F3`/`Shift+F3` stepping with
  wrap-around, match-case and whole-word toggles, two-step Replace (see it selected, then
  replace it), and **Replace All as a single undo step**. The search itself runs
  in the core, so it works identically over a remote core — and any frontend
  gets it over the protocol.
- **Search** — a bottom **Search panel** (`Ctrl+Shift+F`) that finds across three scopes:
  the whole open **project** on disk, all **open documents** (reflecting unsaved edits), or
  just the **current document**. Results are grouped in a list with each hit highlighted in
  its line; double-click a match to jump to it (a disk file opens, an open document switches
  tabs). Match-case, whole-word, and **regex** toggles (line-oriented patterns with `\1`/`&`
  backreferences in replace); case-insensitive by default. A **replace row** (`Ctrl+H`)
  replaces across the same scopes — open documents in the editor (undoable), and a project-wide
  replace (confirmed first) rewrites files on disk while editing any that are open through their
  buffers, so an open view never falls out of step with the disk. The quick in-buffer find bar
  carries the same toggles and can **escalate** into the panel, taking its needle and options
  across. All matching and replacing runs in the core, so it works over the project on whichever
  box the core runs on.
- **Split editor** — show **two buffers side by side** in independent editor groups,
  each with its own tabs (`Ctrl+\` to split). **Drag tabs to reorder them within a
  group or move one across to the other group** (or use the View menu, `Ctrl+]`, or a
  tab's right-click menu). Drag the divider to resize; closing a group's last tab
  unsplits. When a window is too narrow to show every tab, **◂ ▸ arrows** page through
  them, **View ▸ *Switch to Tab…*** lists them all by name in a picker (with a path hint, so same‑named files are easy to tell apart), and **View ▸ *Multi‑Line Tabs***
  wraps them onto several rows instead.
- **Files & git** — open a project folder and browse it in a side pane as an **unfoldable
  tree** — click a folder's arrow (or double-click its name) to unfold it in place and see the
  nested directories you want, fold it back to tidy up (dotfiles are
  hidden by default, like `ls`; a ◉/◌ button in the pane header — or *View ▸ Show Hidden
  Files* — reveals them); **create, rename, and delete** files and folders from the row
  menu (deletes confirm first);
  and view **git status and diffs** for the open repo with **stage, unstage, and
  commit** right from the pane. The file pane keeps itself current — it updates on the
  agent's own writes, when rio regains focus, and on a manual refresh (⟳). Files
  and git share one dockable, resizable side panel. **Drag a file (or folder) from your OS
  file manager onto the window to open it** — a convenience that needs the optional `tkdnd`
  extension and a local core (see [INSTALL.md](INSTALL.md)); without it every other way to
  open a file still works.
- **Compare view** — a **side-by-side diff** of two documents, original beside
  proposed, with added/removed lines coloured and aligned (VSCode-style). Compare
  the active buffer against any file from the View menu.
- **Agent chat** — a right-hand chat column wired to pluggable providers: a
  built-in offline **echo** provider ships in the box, and real agents install from a
  repository as agent-provider extensions (*Settings ▸ Extensions…*) — **Claude** over
  the official Anthropic API and **ChatGPT** over the OpenAI API. ChatGPT is
  OpenAI-*compatible*, so pointing its base URL at a **local** server (Ollama,
  llama-server, LM Studio, vLLM) runs a local model through the same path. Each provider
  brings its own API key, entered under *Preferences ▸ Agent* (a local server may need none). The agent lives in the core
  and runs wherever it does — so over a remote core the turn and your key stay
  server-side, with the same GUI either way (see D30). It holds a streaming
  conversation and can **read your project** (listing folders, reading files and
  open buffers — shown as it works), **propose edits**: it suggests a change or
  a new file, you review the **diff** and **Approve or Reject**, and on approval
  it applies (and, by default, saves) — and **run commands** (tests, a linter, a
  build): it proposes the exact command, you see it and **Approve or Reject**, then
  it runs, confined to your project and time-boxed. A **complex** edit opens live in the
  side-by-side **compare view** (toggleable) rather than inline. Reads run freely;
  every write waits for you (or opt into *Settings ▸ Auto-accept edits*) — and **every
  command always waits for you**, unless you mark it **trusted**: an **Always allow**
  button on the command remembers it (the program, or that exact command) so it stops
  asking — for **all projects**, **this project only**, or **only while a chosen
  provider is running**. It's standing approval you author and manage under *Preferences ▸
  Agent ▸ Allowed commands…*. You can
  **shape how it works** from *Preferences ▸ Agent ▸ Agent Prompts…*: a **system prompt** (your
  standing instructions for every project), a **project prompt** for the open folder, and
  a **per-provider prompt** applied only while a chosen provider (Claude, or an
  OpenAI-compatible model) is the one running. All open in rio's own editor and are plain
  Markdown *added on top of* rio's built-in instructions — never replacing them, and any
  may be left empty. The system and per-provider prompts live with your rio settings; the
  project prompt in a `.rio/agent.md` at the project root, so it travels with the code. The
  instructions live in rio, not the provider — so your general ones shape whichever model
  runs (Claude, ChatGPT, a local model), while the per-provider layer tunes just one.
- **Theming** — live-switchable colour themes from the View menu: the plain
  default, Solarized Dark/Light, Plan 9 Acme, and any theme you install or drop
  in yourself — the menu lists whatever the core can load. Themes are plain
  data files, never executed.
- **Editor font & zoom** — pick the document-view font family and size in *View ▸
  Font…*, or zoom on the fly with **Ctrl+scroll** and **Ctrl++**/**Ctrl+-**
  (**Ctrl+0** resets). Your choice persists and overrides the theme's default.
- **Editing modes** — the text area edits like **Windows** (Notepad/VSCode:
  Ctrl+A selects all, Ctrl+V pastes) — the mode the core ships with. Two more
  install as **extensions** (below): **Emacs/readline** (Ctrl+A/E line motion,
  Ctrl+K kill, Ctrl+V really scrolls) and **vi** (modal: motions, counts,
  `d`/`c`/`y` operators, visual mode, a block cursor in normal mode). Pick one in
  *Settings ▸ Editing Mode*, remembered across runs. A mode is a small
  self-registering file in `modes/` — drop your own in `~/.config/rio/modes/` to
  replace or add one. App shortcuts (save, find, …) always win over the mode's keys.
- **Column / block editing** — Notepad++-style. Turn it on in *Settings ▸ Column
  Editing*, then **Ctrl+Shift+drag** a vertical cursor across many lines: typing,
  Backspace, Delete and Tab all act at that column on every line (one undo);
  drag a width and typing overwrites the rectangular block. Off by default.
- **Extensions & repositories** — install syntax highlighters, editing modes,
  and themes from **repositories you choose**: plain http-served directories,
  apt-sources style, no marketplace and no central index (see below). Browse,
  install, and remove in *Settings ▸ Extensions…*; every installed extension shows
  which repository it came from, same-name extensions from different authors
  coexist and you pick, and it all works over a remote core too.
- **Custom keybindings** — every shortcut is one data table. Remap them in
  *Settings ▸ Keyboard Shortcuts…* (press-to-capture, applied live, no restart) or by
  hand in `~/.config/rio/keys.json`; the menus relabel themselves to match.
- **Syntax highlighting** — colour by language, harmonised with the active theme
  (each theme carries its own `syntax.*` palette, so switching recolours code live).
  The highlighters are small, self-contained files in `syntax/` with no external
  dependencies; a language is easy to add or **swap out** — drop a replacement in
  `~/.config/rio/syntax/` to override the shipped one. **(X)HTML, CSS, JavaScript,
  Perl, Tcl, shell, Markdown, PHP, Python, Lua, C, C#, C++, Go, Rust, and JSON** ship.
- **Sessions** — reopen a project and rio brings back the files you had open and the
  active tab, plus your view preferences (theme, line-wrap, dock side, chat). Even with
  **no folder open**, the loose files you had open come back too — handy for a scratch
  "daily workspace" whose files live in different places. The preferences live with the
  GUI; the open-file set lives with the project on the core, so a **remote session resumes
  too**. Both are plain data, never your API key.
- **Local & remote, one transport** — the GUI always talks to a core over a
  channel. **Locally there is nothing to start**: it spawns its own private core as
  a child process automatically. To edit on **another box**, run the core there
  (after a `git clone`: `./rio-server-deploy.sh` installs `tclsh` + `tcllib` +
  `tcl-tls`, then `tclsh rio-core/server.tcl 7711`, loopback by default), tunnel in
  (`ssh -L 7711:127.0.0.1:7711 host`), and attach:
  `wish rio-gui/rio-gui.tcl --connect 127.0.0.1:7711 /path/on/server` — or, from an
  already-open GUI, **File ▸ Connect to Remote Core…**. Files open and save on
  whichever box the core runs on; browse them from the file tree or the point-and-click
  Open/Save dialogs, which follow the core onto the remote disk. A **stale tunnel is
  noticed within seconds** (not minutes): the GUI watches the link at the protocol
  level and tells you to re-tunnel and reconnect instead of silently hanging.

**Under the hood:** all the logic lives in a **UI-less core**, and the GUI is
**always a client** to one over a channel — a pipe to a private core it spawns
locally, or a socket to a core running elsewhere (**server mode**, like
`emacs-server`). Same op calls either way; there is no separate in-process path.
Frontends are thin views — the core owns your files and broadcasts changes back.

**Still to come:** streaming command output (and a Stop button) for the agent,
the terminal frontend (below), and a polished install/packaging path.
The fuller list of candidate work lives in [ROADMAP.md](ROADMAP.md).

## Extensions & repositories

rio said no to the plugin bazaar — this is the yes it was saving up for. There
is **no marketplace, no store, no central index**: extensions are distributed
the way Debian distributes packages and OpenBSD serves its mirrors — you keep
a short list of **repositories**, and a repository is nothing more than a
**plain http-served directory** anyone can host with a couple of text files in
it. Add a URL under *Settings ▸ Extensions… ▸ Repositories…* and everything it
carries is yours to browse and install; publishing means copying files into
your webdir, and it will still work when today's hosting fashions are gone.

No central index means no central authority — so rio doesn't pretend
otherwise. Every installed extension is marked with its **provenance** (which
repository, which version); when two repositories offer an extension of the
same name, both are listed with author and source and **you choose**; and
installing code (a highlighter, a mode) says plainly that it is code, next to
the URL you're trusting. Themes are data, parsed and never executed.

*Installing:* Settings ▸ Extensions…. *Publishing your own repository:* the
complete spec — three small text files — is in
[CONTRIBUTING.md](CONTRIBUTING.md#extension-repositories).

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

Linux (Debian, Alpine) and **Windows 11** — GUI today; the TUI when it lands. Both are
**run, not assumed**: the full suite passes on each, and a Windows GUI has been driven
against a Linux core over an SSH tunnel, so the remote path is exercised across
platforms too ([RELEASING.md](RELEASING.md) Gate 0 records what that took, and the
handful of things still open). Setup on Windows is one script — see
[WINDOWS.md](WINDOWS.md).

The **BSDs** are a design target rather than a verified one: nothing in rio is
Linux-specific, the deploy scripts cover OpenBSD's `pkg_add`, and the code is the same
portable Tcl — but nobody has yet sat down and run it there, so it is listed honestly
as untested rather than claimed.

## Learn more

- **[INSTALL.md](INSTALL.md)** — install & deployment: requirements, the deploy
  scripts, local vs. remote (server mode over SSH), the agent/Claude key, and
  troubleshooting. rio keeps **no single `~/.riorc`** — one file per concern under
  `~/.config/rio/`; the
  [config & data files reference](INSTALL.md#all-config--data-files-at-a-glance)
  lists them all (paths, contents, which are hand-editable).
- **[AGENTS.md](AGENTS.md)** — the living design & decision log (the *why* behind
  every choice). Start here if you want the full picture.
- **[ROADMAP.md](ROADMAP.md)** — possible next steps: planned features, known gaps,
  and deliberately deferred refinements.
- **[CAVEATS.md](CAVEATS.md)** — known caveats & limitations: cross-platform behaviour
  differences (works on one OS/WM, not another) and deliberate design trade-offs, with their
  mitigations.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — for programmers who want to hack on rio
  itself: toolchain setup, how it's laid out, and how to run the tests.
- **[RELEASING.md](RELEASING.md)** — going-live checklist: the legal, first-run, and
  platform gates that must be true before rio is handed to people who didn't write it.
- **[WINDOWS.md](WINDOWS.md)** — running rio on Windows 11: one deploy script that
  installs the toolchain for you, launch, the daily notes/scratch/logfile workflow in
  keys, and a section for hacking on rio from Windows.
