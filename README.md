# rio — test

A small, cross-platform IDE: a fast, no-nonsense text editor with first-class
git and AI-agent integration — a desktop **GUI** today, a **terminal** frontend
planned, both sharing one UI-less core.

> **North star:** *VSCode's quality, with 90s productivity-software discipline,
> in a fraction of the code, written in Tcl/Tk.* A lightweight VSCode in spirit —
> not a clone, a distillation. Small feature set, small readable codebase, fast.

## Status

**Early implementation** — real and usable, but a long way from the full IDE.
Everything below runs today:

    wish rio-gui/rio-gui.tcl [file ...]

(needs `tclsh`/Tk + `tcllib`, plus `tcltls` for the agent's HTTPS; see
[CONTRIBUTING.md](CONTRIBUTING.md) for setup.)

**What works now (GUI):**

- **Editing** — open and save with encoding and line-ending (LF/CRLF)
  **preservation** (no silent rewrites), range-based editing, undo/redo, several
  buffers as tabs, scrollbars, and optional line wrap.
- **Files & git** — open a project folder and browse it in a side pane; view
  **git status and diffs** for the open repo (read-only for now). Files and git
  share one dockable, resizable side panel.
- **Compare view** — a **side-by-side diff** of two documents, original beside
  proposed, with added/removed lines coloured and aligned (VSCode-style). Compare
  the active buffer against any file from the View menu.
- **Agent chat** — a right-hand chat column wired to two providers: a built-in
  offline **echo** provider, and **Claude** over the official Anthropic API
  (bring your own API key, entered under *Settings*). It holds a streaming
  conversation and can **read your project** (listing folders, reading files and
  open buffers — shown as it works) and **propose edits**: it suggests a change or
  a new file, you review the **diff** and **Approve or Reject**, and on approval
  it applies (and, by default, saves). A **complex** edit opens live in the
  side-by-side **compare view** (toggleable) rather than inline. Reads run freely;
  every write waits for you (or opt into *Settings ▸ Auto-accept edits*).
- **Theming** — live-switchable colour themes from the View menu: the plain
  default, Solarized Dark/Light, and Plan 9 Acme. Themes are plain data files in
  `themes/`, never executed.

**Under the hood:** all the logic lives in a **UI-less core** that the GUI drives
in-process; the very same core can run headless behind a socket (optional
**server mode**, like `emacs-server`). Frontends are thin views — the core owns
your files and broadcasts changes back.

**Still to come:** git write ops (stage/commit), an agent run-command tool (with
guardrails), the terminal frontend (below), and a polished
install/packaging path.

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

- **[AGENTS.md](AGENTS.md)** — the living design & decision log (the *why* behind
  every choice). Start here if you want the full picture.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — for programmers who want to hack on rio
  itself: toolchain setup, how it's laid out, and how to run the tests.

A polished install path and quickstart will land here as rio fills out; for now
the run line above plus CONTRIBUTING's toolchain setup is the way in.
