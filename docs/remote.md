# Working remotely

Editing files that live on another machine, with the window on yours.

**This topic is still to be written.** It will cover: what actually moves (the
*core* runs on the far box; the window stays local and is always a client);
starting a core there and tunnelling in over SSH; attaching with `--connect` or
from ***File ▸ Connect to Remote Core…***; what follows the core onto the remote
disk (the file tree, the Open/Save dialogs, search, git, and the agent — key and
all); what stays local (your preferences, themes, fonts); how a stale tunnel is
noticed within seconds rather than minutes; and the handful of things that only
work with a local core, such as OS file drag-and-drop.

For now, **§4 Deployment modes** in [INSTALL.md](../INSTALL.md) is the complete
guide — requirements on the far box, the deploy script for a slim headless core,
binding and exposure, and the exact commands.

Two things worth knowing before you connect:

- **The agent runs where the core runs.** Over a remote core, the turn is made on
  that machine and your API key is stored there. rio tells you so when you connect;
  it matters if the box isn't yours. See [the agent](agent.md).
- **rio never exposes a core to the network for you, and never dials out either.**
  The core listens on loopback; you reach it over whatever you already trust — an
  SSH tunnel, tailscale, a VPN, a private LAN. rio only ever sees the `host:port`
  at your end, and has no opinion about how it got there.

- [Troubleshooting](troubleshooting.md) — when a connection misbehaves.
