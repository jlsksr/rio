---
title: rio
description: A small, language-agnostic IDE in Tcl/Tk — client-server, network-transparent, no bloat.
---

# rio

**A small, language-agnostic IDE. Tcl/Tk, client-server, no bloat.**

VSCode's good ideas — an editor with real git and an agent workflow — without the
Electron and the telemetry. One readable codebase. Edits any language.

## Highlights

- **Language-agnostic.** An editor, not a Java/JS-specific IDE. Open any file.
- **Tcl/Tk.** No build step, tiny runtime, runs where Tcl runs.
- **Cross-platform.** Linux, the BSDs, Windows. (Terminal frontend later.)
- **Network-transparent.** The GUI is always a client to a *core*; the core runs
  here or on another box. Same UI either way — your files live wherever the core does.
- **Pipes, not sockets.** Locally the GUI spawns a private core and talks to it over
  a pipe — no listening socket, no auth to configure. Remote is what SSH is for.
- **No feature creep.** 90s productivity-software discipline: a feature set that fits
  in your head, not a plugin bazaar.
- **git + agent, built in.** Branch status, diffs, and an AI agent that reads your
  project and proposes edits — which you approve or reject as diffs.

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

Early but real — editing with encoding/EOL preservation, tabbed buffers, git
status/diffs, a side-by-side compare view, theming, the agent (read + propose-edit),
and a local *or* remote core all work today. Terminal frontend and git write ops are
next.

See [README.md](README.md) for the feature list, [INSTALL.md](INSTALL.md) to deploy,
[AGENTS.md](AGENTS.md) for the design log.
