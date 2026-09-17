# Troubleshooting

What to check when rio doesn't do what you expect.

**This topic is still to be written.** It will cover the user-side faults: a
setting that doesn't stick, a shortcut that doesn't fire, a theme or mode that
doesn't appear after installing, the agent refusing to run, a remote connection
that goes quiet, and how to tell a rio bug from a platform quirk.

Two other documents already answer most of it, and this page will point at them
rather than repeat them:

- **[CAVEATS.md](../CAVEATS.md)** — known rough edges and behaviour that differs
  between platforms and window managers ("works on one OS, not another"), each with
  its mitigation. Check here first: if what you hit is listed, it is known and
  there is usually a way around it.
- **[INSTALL.md](../INSTALL.md) §7** — *Lifecycle, shutdown & troubleshooting*, for
  deployment faults: stopping things cleanly, a core host missing `tcltls`, and the
  package names each platform wants.

On Windows, [WINDOWS.md](../WINDOWS.md) also covers getting an error message out of
`wish`, which prints none for an uncaught error.

Some messages already have their answer written down:

- **`rio needs the Tcl package …, which isn't installed on this host`** — rio checks
  what it cannot run without before it does anything else, and says which package is
  missing, which OS package provides it (`tcllib` on Debian and the BSDs, `tcl-lib` on
  Alpine, and so on), and that the full table is in
  [INSTALL.md](../INSTALL.md) section 1. Install it and start rio again. The window
  shows the same words in a message box, because on Windows there is no console for
  them to land in.
- **`rio could not start its core`** — the window starts its own core as a child
  process, and this one exited or stopped answering while starting up. The message
  names the exact command to run by hand: run it in a terminal and the core's own
  complaint is right there, a missing dependency being the usual one.
- **`certificate not trusted`** on a repository in the Extensions window — see
  [a certificate that isn't trusted](extensions.md#a-certificate-that-isnt-trusted).
- **The agent refused https**, naming `tcltls` and host-name checks — see
  [HTTPS on an older tcltls](agent.md#https-on-an-older-tcltls). A repository says
  `https needs tcltls 1.8 or newer` for the same reason, with the same way out and one
  more: upgrade `tcltls` on the core's host, use the repository's `http://` URL, or
  turn on the switch, which covers both, in [Preferences ▸ Network](preferences.md#network-how-the-core-checks-https).

## Further reading

- [Preferences](preferences.md#where-everything-lives) — every config file, so you
  can look at (or move aside) the one you suspect.
- [Working remotely](remote.md) — what a remote core does and doesn't change.
