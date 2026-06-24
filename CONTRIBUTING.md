# Contributing to rio

rio is a small, cross-platform IDE: a fast, no-nonsense text editor with proper
git and AI-agent support, available both as a desktop GUI and in the terminal.
If you like editors that stay out of your way — and software whose source you can
actually sit down and read — you'll feel at home here.

This guide is for programmers who want to hack on rio itself. Welcome; we're glad
you're here.

> **Heads-up:** rio is still in early design — there isn't a working build yet,
> so the *Getting started* and *Tests* sections below are placeholders for now.
> The architecture is settled, though. If you want the full reasoning behind how
> rio is put together, it's all written up in [AGENTS.md](AGENTS.md).

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

*Coming soon.* The build and toolchain aren't pinned down yet (rio doesn't have
code to build at the time of writing). Once the core exists, this section will
walk you through building and running both the GUI and the terminal version.

## Tests

*Coming soon.* One nice consequence of keeping all the logic in a UI-less core:
most of it can be tested without spinning up an interface. We'll document the
test setup alongside the first real code.

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
