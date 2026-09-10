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

- [Preferences](preferences.md#where-everything-lives) — every config file, so you
  can look at (or move aside) the one you suspect.
- [Working remotely](remote.md) — what a remote core does and doesn't change.
