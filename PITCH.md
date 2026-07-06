---
title: rio
description: A small, language-agnostic IDE in Tcl/Tk — client-server, network-transparent, no bloat.
---

# rio

**A small, language-agnostic IDE. Tcl/Tk, client-server, no bloat.**

Written **from scratch** — no framework, no fork, no Electron. rio aims for the
**sweet spot between Windows 2000-era productivity software and a modern IDE like
Visual Studio Code**: menus and panes you already know from a desktop app that
booted instantly and never phoned home, carrying the ideas worth keeping from VSCode
— a real editor, real git, an AI-agent workflow — in one readable codebase that edits
any language.

## Highlights

- **Built from scratch.** No editor toolkit, no Electron, no vendored framework —
  the editor, the git integration, the diff view, the agent loop, and the wire
  protocol are all rio's own code, and small enough to read in an afternoon.
- **The sweet spot.** Windows 2000-era discipline — instant start, a menu bar, a
  feature set that fits in your head — with the VSCode ideas worth keeping: split
  editing, side-by-side diffs, syntax highlighting, and a propose-and-approve agent.
- **Language-agnostic.** An editor, not a Java/JS-specific IDE. Open any file.
- **Tcl/Tk.** No build step, tiny runtime, runs where Tcl runs.
- **Cross-platform.** Linux, the BSDs, Windows. (Terminal frontend later.)
- **Network-transparent.** The GUI is always a client to a *core*; the core runs
  here or on another box. Same UI either way — your files live wherever the core does.
- **Pipes, not sockets.** Locally the GUI spawns a private core and talks to it over
  a pipe — no listening socket, no auth to configure. Remote is what SSH is for.
- **No feature creep.** A feature set that fits in your head, not a plugin bazaar.
- **git + agent, built in.** Branch status, diffs, and an AI agent that reads your
  project and proposes edits — which you approve or reject as diffs.

## What rio does today

Every item below runs now, in the GUI:

- **Editing** — open and save with **encoding and line-ending (LF/CRLF) preservation**
  (no silent rewrites), range-based edits, undo/redo, tabbed buffers, scrollbars,
  optional line wrap.
- **Split editor** — two buffers **side by side** in independent groups, each with its
  own tabs (`Ctrl+\` to split). **Drag a tab from one group to the other**, or move it
  from the View menu / a tab's right-click menu; drag the divider to resize; closing a
  group's last tab unsplits.
- **Files & git** — open a project folder and browse it in a dockable, resizable side
  pane; view **git status and diffs** for the repo (read-only for now).
- **Compare view** — a **side-by-side diff** of two documents, added/removed lines
  coloured and aligned, VSCode-style.
- **AI agent** — a chat column wired to an offline **echo** provider and to **Claude**
  over the official Anthropic API (bring your own key). It streams, **reads your
  project** (folders, files, open buffers — shown as it works), and **proposes edits**
  you review as a **diff** and **Approve or Reject**; reads run freely, every write
  waits for you. Because the agent lives in the core, over a remote core your key and
  its HTTPS stay server-side.
- **Theming** — live-switchable themes (plain default, Solarized Dark/Light, Plan 9
  Acme), plain data files that are never executed.
- **Syntax highlighting** — per-language colour harmonised with the active theme;
  highlighters are small self-contained files you can add or swap out. (X)HTML ships.
- **Sessions** — reopen a project and rio restores the open files, active tab, and your
  view preferences; a **remote session resumes too**.
- **Local *or* remote, one transport** — locally there's nothing to start (the GUI
  spawns its own private core); to edit on another box, run the core there and attach
  over SSH. Same UI, same ops, either way.

## Architecture

Three pieces, one protocol:

- **core** — UI-less. Owns your files, git, undo, and the agent loop. Speaks a small
  JSON-line protocol over a channel: a pipe locally, a socket over SSH remotely.
- **GUI** — a thin Tk view. It renders, and sends keystrokes as ops; it never touches
  your files directly. The core broadcasts every change back to it.
- **TUI** — a curses frontend over the same core. Prototyped, deferred.
- **plugins** — e.g. the Claude provider. The protocol is language-neutral, so a
  frontend or client can be written in anything.

Frontends are dumb views, so "remote" comes for free: run the core on a server,
attach a GUI over SSH, edit as if local. The agent runs *in the core* too — so with a
remote core, your API key and its HTTPS stay server-side.

## Quickstart (local)

```sh
git clone <repo> rio && cd rio
./rio-dev-deploy.sh            # tcl, tk, tcltls, tcllib, git
wish rio-gui/rio-gui.tcl .     # open the current dir as a project
```

Nothing else to start — the GUI spawns its own core.

## Remote (the gist)

```sh
# on the server:
./rio-server-deploy.sh && tclsh rio-core/server.tcl 7711      # loopback only

# on your machine:
ssh -NL 7711:127.0.0.1:7711 you@server
wish rio-gui/rio-gui.tcl --connect 127.0.0.1:7711 /path/on/server
```

SSH does the auth and crypto; the core never faces the network itself. Full recipe in
[INSTALL.md](INSTALL.md).

## Why

I hate bloated software. I'd wanted to build something real in Tcl/Tk for years, and
I wanted a project meaty enough to actually test agent-assisted coding. Then I finally
used VSCode, liked the shape of it, and decided to build a smaller one: the parts I
use, in a codebase I can read in an afternoon.

## Status

Early but real — editing with encoding/EOL preservation, tabbed buffers, a split
editor with drag-between-groups, git status/diffs, a side-by-side compare view,
theming, syntax highlighting, the agent (read + propose-edit), and a local *or*
remote core all work today. Terminal frontend and git write ops are next.

See [README.md](README.md) for the feature list, [INSTALL.md](INSTALL.md) to deploy,
[AGENTS.md](AGENTS.md) for the design log.
