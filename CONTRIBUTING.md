# Contributing to rio

rio is a small, cross-platform IDE: a fast, no-nonsense text editor with proper
git and AI-agent support, available both as a desktop GUI and in the terminal.
If you like editors that stay out of your way — and software whose source you can
actually sit down and read — you'll feel at home here.

This guide is for programmers who want to hack on rio itself. Welcome; we're glad
you're here.

> **Heads-up:** rio is in early days. The UI-less core does real work now —
> open/save with encoding and line-ending preservation, range-based editing, and
> undo/redo — and there's a minimal but real Tk editor (`rio-gui`) wired on top of
> it. It's far from a finished IDE, but you can open a file, edit it, undo, and
> save. The architecture is settled and there are real tests to run (below). The
> full reasoning behind how rio is put together is in [AGENTS.md](AGENTS.md).

## What rio cares about

A few values, so you know the kind of changes that fit:

- **Small and simple.** rio is meant to be understood by one person in an
  afternoon. Resist feature creep; the goal isn't to out-feature the big IDEs.
- **Readable beats clever.** Clear code that the next person can follow wins over
  a tighter trick. Comment where it helps, name things well.
- **Efficient, in the 90s-productivity sense** — quick, sharp, no wasted motion
  for the user.
- **Cross-platform, honestly.** Linux, the BSDs, and Windows; a GUI and a
  terminal version that share the same brain.

## How the code is laid out

rio is split into three kinds of thing, and knowing the split tells you where
your code belongs:

- **The core** holds all the real logic — open files, editing, undo, git, the
  agent machinery, project state. It has *no* user interface and could run on its
  own. This is where most of the code lives.
- **The frontends** are the desktop GUI (built with Tk) and the terminal UI
  (built with Ck, a curses toolkit). They're deliberately thin: they draw what
  the core tells them and send back what you type. They don't make decisions.
- **Plugins** are separate programs that talk to the core. This is how things
  like LLM providers (Claude, a local model) and other extensions hook in,
  without bloating the core.

**Rule of thumb:** if you're writing actual logic, it almost certainly belongs in
the core. Keep the frontends dumb.

## A few house rules

- **Logic in the core, not the UI.** If you're tempted to put behaviour in the
  GUI or TUI, it probably wants to be in the core instead.
- **The core owns your open files; the frontends are just windows onto them.**
  Edits flow as commands into the core, and the views refresh from it.
- **Keep the GUI and the terminal version in step.** Shared behaviour, different
  drawing — a feature shouldn't work in one and not the other.
- **Reach for a plugin before growing the core.** Anything beyond the essentials
  is a good candidate to live outside.
- **Match the style of the code around you.**

The *why* behind all of these is in [AGENTS.md](AGENTS.md) if you're curious.

## Extending rio

rio is meant to be extended through plugins — small separate programs that speak
rio's protocol (in whatever language you like), or lightweight ones running
in-process. LLM providers and extra agent tools are built this way.

The plugin interface is still being designed and *will* change, so it's not the
place to start contributing yet. If you want to follow or shape that design, it's
covered in [AGENTS.md](AGENTS.md).

## Getting started

There's no rio to build yet, but you can get the toolchain in place. rio is
written in Tcl/Tk, so you'll need `tclsh` and Tk, plus a couple of small
libraries — `tcltls` (for the agent's HTTPS) and `tcllib` (for JSON) — and
`git`.

The quickest way is the setup script in the repo root:

    ./rio-dev-deploy.sh                # install the core toolchain
    ./rio-dev-deploy.sh --verify-only  # just check what you already have

It works on Debian/Ubuntu, Alpine, and OpenBSD, and finishes by loading the
pieces through `tclsh` so you know they actually work. If you also want to hack
on the terminal version, add `--with-ck` to build the curses toolkit from
source — otherwise skip it; the GUI doesn't need it.

With the toolchain in place you can run the GUI editor — it embeds the core
in-process, so there's nothing else to start:

    wish rio-gui/rio-gui.tcl [file]

Open a file with Ctrl+O, save with Ctrl+S, undo/redo with Ctrl+Z / Ctrl+Shift+Z.
The terminal version (Ck) doesn't exist yet; build-and-run steps for it will land
here when it does.

## Tests

One nice consequence of keeping all the logic in a UI-less core: most of it can
be tested without spinning up an interface — which is exactly how we test it. The
suite uses Tcl's own `tcltest`:

    tclsh rio-core/tests/all.tcl

Tests live in `rio-core/tests/`, one `.test` file per area. If you add behaviour
to the core, add a case alongside it; a change to how editing works should show
up as a test that would have failed before.

The GUI has a headless smoke that drives the real frontend (open / edit through
the dumb-view proxy / save / undo) without ever showing a window — it needs a
display but stays off-screen:

    RIO_GUI_HEADLESS=1 wish rio-gui/tests/smoke.tcl

## Sending a change

- **Keep it focused.** One concern per change, small enough to review comfortably.
- **Keep the docs honest.** If your change shifts a design decision, note it in
  [AGENTS.md](AGENTS.md); user-facing changes belong in the README (and, later,
  the wiki).
- **Say why.** A short explanation of the reasoning — especially for anything
  touching the core's protocol — makes review much easier.

## License & code of conduct

*To be added before rio opens up to outside contributions.*

---

Want the deep design rationale — why rio is built the way it is, and the
trade-offs behind each decision? That's all in [AGENTS.md](AGENTS.md). Start
there.
