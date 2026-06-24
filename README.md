# rio

A small, cross-platform IDE: a fast, no-nonsense text editor with first-class
git and AI-agent integration — available both as a desktop **GUI** and in the
**terminal**, sharing one core.

> **North star:** *VSCode's quality, with 90s productivity-software discipline,
> in a fraction of the code, written in Tcl/Tk.* A lightweight VSCode in spirit —
> not a clone, a distillation. Small feature set, small readable codebase, fast.

## Status

**Pre-implementation.** rio is in the design phase — there is **no build yet**,
so there's nothing to install or run today. The architecture is settled and
written down; code comes next.

- **What it will do:** edit files, integrate with git (status, diff, stage,
  commit), and assist coding with an AI agent (Claude or a local LLM) via a chat
  + propose-diff + apply/reject flow.
- **Two faces, one brain:** a Tk GUI and a curses (Ck) TUI over a shared,
  UI-less core — like `emacs` and `emacs-nox`.
- **Cross-platform:** Linux, the BSDs, and Windows.

## Learn more

- **[AGENTS.md](AGENTS.md)** — the living design & decision log (the *why* behind
  every choice). Start here if you want the full picture.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — for programmers who want to hack on rio
  itself.

Install instructions and a quickstart will land here once there's something to
run.
