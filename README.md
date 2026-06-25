# rio

A small, cross-platform IDE: a fast, no-nonsense text editor with first-class
git and AI-agent integration — available both as a desktop **GUI** and in the
**terminal**, sharing one core.

> **North star:** *VSCode's quality, with 90s productivity-software discipline,
> in a fraction of the code, written in Tcl/Tk.* A lightweight VSCode in spirit —
> not a clone, a distillation. Small feature set, small readable codebase, fast.

## Status

**Early implementation.** The UI-less core and a minimal Tk editor work today:
you can open files, edit them, undo/redo, work across several buffers as tabs,
and save — with encoding and line-ending (LF/CRLF) preservation. It's a long way
from the full IDE below, but it runs:

    wish rio-gui/rio-gui.tcl [file ...]

(needs `tclsh`/Tk + `tcllib`; see [CONTRIBUTING.md](CONTRIBUTING.md) for setup.)

- **What it will do:** beyond editing — integrate with git (status, diff, stage,
  commit), and assist coding with an AI agent (Claude or a local LLM) via a chat
  + propose-diff + apply/reject flow. Not built yet.
- **Two faces, one brain:** a Tk GUI (working) and a curses (Ck) TUI (not built
  yet) over a shared, UI-less core — like `emacs` and `emacs-nox`.
- **Cross-platform:** Linux, the BSDs, and Windows.

## Learn more

- **[AGENTS.md](AGENTS.md)** — the living design & decision log (the *why* behind
  every choice). Start here if you want the full picture.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — for programmers who want to hack on rio
  itself.

A polished install path and quickstart will land here as rio fills out; for now
the run line above plus CONTRIBUTING's toolchain setup is the way in.
