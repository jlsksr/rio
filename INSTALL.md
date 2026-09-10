# Installing & deploying rio

The canonical home for how to get rio running — local GUI, remote/server mode, and
the agent. For *why* it's built this way, see [AGENTS.md](AGENTS.md); for hacking on
rio, [CONTRIBUTING.md](CONTRIBUTING.md).

rio is two thin frontends over one UI-less **core**. The GUI is **always a client**
to a core over a channel — there is no in-process path. So "deploying rio" is really
two questions: *where does the core run* (here, or another box), and *what does that
box need installed*.

---

## 1. Requirements

The **core** needs:

| Need | Package (apt / apk) | OpenBSD (`pkg_add`) | Why |
|------|---------------------|---------------------|-----|
| `tclsh` 8.6+ | `tcl` | `tcl%8.6` | the interpreter the core runs on |
| `tcllib` | `tcllib` (Alpine: `tcl-lib`) | `tcllib` | the `json` package the wire protocol uses |
| `tcltls` | `tcl-tls` | `tcltls` | **the agent's Claude HTTPS — runs in the core (D30)** |
| `git` *(optional)* | `git` | `git` | the git pane shells out to it |

The **GUI** additionally needs **Tk** (`tk` / `tk%8.6`). The GUI host does **not**
need `tcltls` — the agent's HTTPS happens wherever the *core* runs. Extension
repositories (D39) add **no dependency anywhere**: they are fetched over plain
HTTP by the core, with Tcl's own `http` package.

> `http` (used by the TLS transport) ships with Tcl itself — no separate package.

**Optional — `tkdnd`** (drag a file onto the window to open it, D86). rio-gui loads it if
present and works without it; the hard dependency bar stays Tk + json. Install it to enable
OS drag-to-open (Debian/Ubuntu `tklib`-adjacent package `tkdnd`; Alpine/OpenBSD via ports if
packaged; Windows the Magicsplat Tcl/Tk distribution bundles it). Without it, dragging a file
onto the window simply does nothing — every other way to open a file is unaffected. Drag-to-open
also needs a **local** core: a dropped path is on the GUI's own machine, so it isn't offered
against a remote core.

A wide pseudo-glyph note: rio's UI uses monochrome Unicode glyphs, so a font with
reasonable coverage helps, but nothing extra is required.

---

## 2. Quick start (everything local)

The common case: edit on the machine you're sitting at. **There is nothing to start
manually** — the GUI spawns its own private core as a child process and talks to it
over a pipe.

```sh
git clone <repo> rio && cd rio
./rio-dev-deploy.sh            # installs tcl, tk, tcltls, tcllib, git (+ verifies)
wish rio-gui/rio-gui.tcl [file-or-folder ...]
```

A directory argument opens as the project folder; a file opens in a tab. With no
argument you get an empty scratch buffer.

Out of the box the only agent provider is the offline **echo** stub. To use a real
agent, **install a provider** from *Settings ▸ Extensions…* (e.g. **Claude** over the
Anthropic API, or **ChatGPT** over the OpenAI API), restart rio, then pick it under
*Settings ▸ Agent Provider* and enter its key under *Preferences ▸ Agent* (stored
0600 — see §5).

---

## 3. The install scripts

The two POSIX ones are `sh`, idempotent, and finish by **verifying the toolchain
actually loads** (the real source of truth). They target Debian/Ubuntu (`apt`), Alpine
(`apk`), and OpenBSD (`pkg_add`), picking `sudo`/`doas` only when not already root.

Shared flags: `--verify-only` (check, don't install), `--dry-run` (print the steps),
`-h`/`--help`.

There is a **third, for Windows**: `rio-dev-deploy.ps1` (§8, and
[WINDOWS.md](WINDOWS.md) §1). Same contract — offer to install, then verify by loading
— with `winget install Magicsplat.TclTk` standing in for `apt`/`apk`, and
`-VerifyOnly` / `-DryRun` / `-Help` mirroring the flags above.

### `rio-dev-deploy.sh` — full GUI / dev toolchain

Installs `tcl` + `tk` + `tcltls` + `tcllib` + `git`, then verifies `Tk`, `tls`, and
`json` load.

```sh
./rio-dev-deploy.sh                 # GUI + agent toolchain
./rio-dev-deploy.sh --with-ck       # also build Ck (curses Tk) from source — the
                                    # deferred TUI path (AGENTS.md O1); only if you
                                    # mean to work on the terminal frontend
```

`--with-ck` additionally pulls a C toolchain + ncurses headers and builds the
`vzvca/ck8.6` fork (distros don't package it). On a shared-build error finding
`libck8.6.so`, run `ldconfig` or set `LD_LIBRARY_PATH` to the install libdir.

### `rio-server-deploy.sh` — slim headless core

For a box that runs **only the core** (no GUI). Installs `tcl` + `tcllib` +
`tcl-tls` (Tk-free, but TLS is needed for server-side Claude), plus `git` unless
`--no-git`. Verifies `json` + `tls` load and that `server.tcl` sources and binds a
throwaway port.

```sh
./rio-server-deploy.sh              # slim runtime
./rio-server-deploy.sh --no-git     # skip git (no git pane over the socket)
./rio-server-deploy.sh --verify-only
```

If it reports `tls MISSING`, a Claude turn would fail later with *"can't find
package tls"* — install the package (table in §1) and re-run.

---

## 4. Deployment modes

The GUI reaches a core in one of two ways; **the op calls and the UI are identical**
either way — only *where the files and the agent live* differs.

### A. Local — a spawned private core (default)

No flags. The GUI runs `tclsh rio-core/server.tcl --stdio` as a child and speaks
over its stdio pipe. No listening socket exists, so there's nothing on a shared host
to connect to; process ownership is the access control. The core shares your
filesystem and runs as you. Closing the GUI (or it dying) EOFs the pipe and the core
exits with it.

```sh
wish rio-gui/rio-gui.tcl [path ...]
```

### B. Remote — a core on another box, over an SSH tunnel

Run the core on the far box bound to **loopback** (the default), forward a port with
SSH, and attach the GUI to the local end. SSH provides the auth and encryption — the
core has none of its own (see §7).

**On the server** (after `rio-server-deploy.sh`):

```sh
tclsh rio-core/server.tcl 7711          # listens on 127.0.0.1:7711
```

**On your workstation:**

```sh
ssh -N -L 7711:127.0.0.1:7711 you@server    # forward the port (leave it running)
wish rio-gui/rio-gui.tcl --connect 127.0.0.1:7711 /path/on/server
```

Notes:
- The path argument lives on the **server**; the GUI can't stat the remote FS
  directly, so it browses it through the core. Point-and-click either from the file
  tree or from **Open / Save As / Open Folder**, which in remote mode become a
  server-side browser (walking the core's disk, with a Location bar to type a known
  path). The core is the document of record — edits and saves happen on the server's
  disk.
- **Sessions and preferences persist**, and because the workspace lives with the
  **core**, resuming a project works over a remote core too — your open files follow
  the project onto the server. Where these live and how to set global defaults:
  [docs/preferences.md](docs/preferences.md).
- If the tunnel maps a different remote port (e.g. `-L 7711:127.0.0.1:7712`), the
  **core listens on `7712`** on the server; the GUI still connects to your local
  `7711`.
- `RIO_CONNECT=host:port` is an alternative to `--connect`.
- You can also connect from an **already-running GUI**: **File ▸ Connect to Remote
  Core…**, enter the `host:port`. By default it rewires that window to the remote
  core (offering to save open tabs first); tick **Open in a new window** to keep the
  current session and open the remote one alongside it.
- A daemon serves several frontends, but there's **one core per attach**, no shared
  live cursor state across windows.

### Binding & exposure

`server.tcl` defaults to `127.0.0.1:7711`. Override:

```sh
tclsh rio-core/server.tcl 0           # 0 = OS-assigned ephemeral port
tclsh rio-core/server.tcl 7711 --any  # bind ALL interfaces (RIO_BIND=0.0.0.0 too)
```

**Only use `--any` behind a firewall** — the socket has no auth or crypto. The
intended remote story is loopback + SSH (mode B), not a public socket.

---

## 5. The agent — where the key and HTTPS live

Since D30 the **agent runs inside the core**, so a hosted provider's HTTPS (Claude,
ChatGPT) happens **wherever the core runs** — locally in mode A, on the server in mode B.
Consequences:

- **`tcltls` must be installed on the core's host.** A core without it fails the first
  hosted-provider turn with *"can't find package tls"* (the message names the fix).
- **The API key is stored by the core**, in a 0600 file under
  `$XDG_DATA_HOME/rio/secrets/` (default `~/.local/share/rio/secrets/`) **on the core's
  host** — one file per provider (Claude's is `claude-api.secret`) — never in the GUI,
  never in synced config. In mode B the key lives on the **server**. Enter/clear it from
  *Preferences ▸ Agent* (it crosses the channel once via `agent.key.set`; the GUI
  never retains it).
- **Don't want the key on a given box?** Run the core locally (mode A) and edit
  remote files some other way — the GUI is identical. The choice of *where the agent
  runs* is just *where you point the GUI*.
- **Provider** is chosen at runtime (*Settings ▸ Agent Provider*). The only built-in is
  `echo`, an offline stub needing no key or network; a real provider (Claude, ChatGPT, …)
  is **installed** from *Settings ▸ Extensions…* and needs a stored key + `tcltls`.

The provider/key/policy are core ops (`agent.provider.set`, `agent.key.set` /
`clear`, `agent.autoaccept.set`, `agent.status`), so they behave the same against a
local or remote core.

---

## 6. Preferences, config files & shortcuts — see the manual

These three references used to live here, and have moved to the **user manual** in
[docs/](docs/index.md): they are *how to use rio*, not how to install or deploy it,
and keeping them here is what let the shortcut table drift out of date.

| Looking for | Now at |
| ----------- | ------ |
| Preferences & defaults — every setting, `prefs.json`, editing modes, `sources.list` | [docs/preferences.md](docs/preferences.md) |
| All config & data files at a glance — the whole XDG layout, config and data | [docs/preferences.md — *Where everything lives*](docs/preferences.md#where-everything-lives) |
| Keyboard shortcuts — the default chords and `keys.json` | [docs/keyboard.md](docs/keyboard.md) |

Two facts belong here and stay here, because they are deployment concerns:

- **Preferences live on the box running the GUI**, and the per-project workspace
  lives with the **core** — so a remote setup keeps your theme and layout local
  while the open-file set resumes from the server.
- **No settings file ever holds an API key.** The key lives on its own in the
  `0600` secrets store described in §5, on whichever box the core runs on.

---

## 7. Lifecycle, shutdown & troubleshooting

**Stopping things.**
- *Mode A:* close the GUI window or *File ▸ Quit* — the pipe EOFs and the core exits
  with the GUI. Killing the GUI (even abruptly) closes the pipe, so the child core
  doesn't outlive it.
- *Mode B:* the daemon is a normal foreground process — `Ctrl-C` (SIGINT) stops it;
  or `pkill -f rio-core/server.tcl`. The daemon banner prints its `pid`. A
  background/`&`'d daemon won't take `Ctrl-C` (the shell sets it to ignore the
  signal) — use `kill`/`pkill`.

**"Couldn't reach Claude … (can't find package tls)".** Not a network problem — the
error came *back* from the core, so the link is fine. The **core's host** is missing
`tcltls`. Verify on that host:

```sh
echo 'package require tls' | tclsh        # prints a version, or "can't find package tls"
```

Install the package (§1). If it prints a version but you still see the error, the
running daemon **predates the install** — restart it (`pkill -f rio-core/server.tcl`
then start it again).

**"Lost the connection to the core (disconnected)".** *This* is the real
connectivity error: the core exited, or the SSH tunnel dropped. Check the daemon is
running on the server and the tunnel is up.

**`tls MISSING` / wrong package name.** The package names above are confirmed for
apt/apk; OpenBSD uses `tcltls`. If a name differs on your system, fix it in the
relevant `install_*` function — the script's verifier confirms the result.

**Re-running a deploy script is safe** — installs are idempotent and it re-verifies.

---

## 8. Platforms

Linux (Debian, Alpine) and the BSDs are the deploy targets the POSIX scripts cover.
**Windows 11 is automated too** — `rio-dev-deploy.ps1` is the counterpart to
`rio-dev-deploy.sh`: it offers to `winget install` the Tcl/Tk toolchain (asking
first), verifies it loads, and sets up persistence, so setup there is also one
command. See [WINDOWS.md](WINDOWS.md) for the Windows 11 quick start and, at the end,
a section on hacking on rio from Windows.

Linux and Windows are **verified** — the full suite passes on both, including a
Windows GUI driven against a Linux core over an SSH tunnel ([RELEASING.md](RELEASING.md)
Gate 0). The BSDs remain a design target that nobody has yet run.

The TUI (Ck) frontend is **deferred** — present only behind `--with-ck` for
development, not a supported runtime yet (AGENTS.md O1).
