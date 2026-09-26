# Troubleshooting

What to check when rio does not do what you expect.

**This topic is still to be written.** It will cover the user-side faults: a
setting that does not stick, a shortcut that does not fire, a theme or mode that
does not appear after installing, the agent refusing to run, a remote connection
that goes quiet, and how to tell a rio bug from a platform quirk.

## Check these first

- **[CAVEATS.md](../CAVEATS.md)** — known rough edges, and behaviour that
  differs between platforms and window managers, each with its way around. If
  what you hit is listed, it is known.
- **[INSTALL.md](../INSTALL.md) §7** — *Lifecycle, shutdown & troubleshooting*,
  for deployment faults: stopping things cleanly, a core host missing `tcltls`,
  and the package names each platform wants.
- **[WINDOWS.md](../WINDOWS.md)** — on Windows, how to get an error message out
  of `wish`, which prints none for an uncaught error.

## Messages that already have an answer

| Message | What to do |
| ------- | ---------- |
| **`rio needs the Tcl package …, which isn't installed on this host`** | rio checks what it cannot run without before doing anything else. The message names the missing package, the OS package that provides it (`tcllib` on Debian and the BSDs, `tcl-lib` on Alpine, and so on), and points at [INSTALL.md](../INSTALL.md) section 1. Install it and start rio again. |
| **`rio could not start its core`** | The window starts its own core as a child process, and this one exited or stopped answering. The message names the exact command to run by hand: run it in a terminal and the core's own complaint is right there. A missing dependency is the usual cause. |
| **`certificate not trusted`** on a repository row | See [a certificate that isn't trusted](extensions.md#a-certificate-that-isnt-trusted). |
| **`signing key not confirmed`** on a repository row | Nothing is wrong. It signs with a key you have never confirmed, and rio installs nothing from a repository until you do. Select the row, press **Review signing key…**, and see [confirming a repository's key](extensions.md#confirming-a-repositorys-key). |
| **`signing key changed`**, **`signature doesn't verify`**, **`signature missing`**, **`no longer signed`**, **`files don't match the signature`** | Its signature did not check out, so nothing from it is offered. Select the row for the whole sentence, and see [when rio refuses a signed repository](extensions.md#when-rio-refuses-a-signed-repository). A changed key can be reviewed and accepted from that row. |
| **`can't check the signature`** | A repository whose key you confirmed, and no way to check it: the core's host has no `ssh-keygen` from OpenSSH 8.0 or newer, or the core itself predates repository signing. Fix that on the core's host, or see [repositories rio can't check](extensions.md#repositories-rio-cant-check). |
| **The agent refused https**, naming `tcltls` and host-name checks | See [HTTPS on an older tcltls](agent.md#https-on-an-older-tcltls). A repository says `https needs tcltls 1.8 or newer` for the same reason: upgrade `tcltls` on the core's host, use the repository's `http://` URL, or turn on the switch in [Preferences ▸ Network](preferences.md#network-how-the-core-checks-https), which covers both. |

## Further reading

- [Preferences](preferences.md#where-everything-lives) — every config file, so
  you can look at, or move aside, the one you suspect.
- [Working remotely](remote.md) — what a remote core does and does not change.
