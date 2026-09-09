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
  the project onto the server. Where these live and how to set global defaults: §6.
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

## 6. Preferences & defaults

rio persists two kinds of state, split by owner (the design is [AGENTS.md](AGENTS.md)
D31):

- **Preferences** — theme, line-wrap, wrapped-line indent, dock side/pane, chat-pane visibility. These are
  **global** and belong to the GUI, in `$XDG_CONFIG_HOME/rio/prefs.json` (default
  `~/.config/rio/prefs.json`) on the box running the GUI. They load at **every**
  startup — with or without a project — so a bare `wish rio-gui/rio-gui.tcl file.txt`
  opens with your saved wrap, theme, and layout.
- **Workspace** — the files you had open in a project and the active tab. This is
  **per-project** and belongs to the core, kept out of tree under
  `$XDG_DATA_HOME/rio/sessions/` (default `~/.local/share/rio/sessions/`), keyed by
  project root. It resumes only when a **project** is open (you launched at a folder,
  or opened one); a bare file has no project, so nothing per-project is restored.

Neither file ever holds your API key — that stays in the 0600 secrets store (§5).

**Setting a default is just setting the value** — the last value *is* the default,
saved the moment you change it:

- **From the UI:** the **View** menu (Wrap Lines, Indent Wrapped Lines, the theme
  entries, Dock Left/Right, Agent Chat), the **Settings** menu (Column Editing),
  and the shortcuts (`Ctrl+Shift+W` wrap, `Ctrl+Shift+A` chat). Each toggle
  rewrites `prefs.json` at once and is restored next launch.
- **By hand:** edit `prefs.json` directly — it is plain JSON, parsed never executed:

  ```json
  {"theme":"solarized-dark","wrap":"1","wrap_indent":"1","line_numbers":"1","column_edit":"0","editmode":"windows","layout":{ … }}
  ```

  `wrap` `"1"` = word-wrap on, `"0"` = off; `wrap_indent` `"1"` aligns a wrapped
  line's continuation rows under its own indentation (only visible while `wrap` is
  on), `"0"` leaves them at the left margin; `line_numbers` `"1"`/`"0"` shows or hides
  the gutter; `column_edit` `"1"` enables Notepad++-style column/block editing
  (Ctrl+Shift+drag a vertical cursor, then type/Backspace/Delete/Tab down the whole
  column), `"0"` off; `theme` is a name from `themes/` (or `default`); `editmode` is
  `windows`/`vi`/`emacs` (the last two only take effect once installed as extensions —
  below). `layout` is a **nested object** holding the whole dock arrangement (which
  panes sit left/right/bottom, which are hidden, sizes) — it replaced the old flat
  `dock_side`/`dock_pane`/`chat_shown` keys (D35); it is fiddly to write by hand, so
  toggle it from the **View** menu and let rio record it. The file appears once you
  first change a setting (or quit), and you may create it by hand before the first run.
  Unknown or malformed keys are ignored, and a corrupt file is skipped rather than fatal.

> **Note.** There is not yet a *separate* hand-authored settings file distinct from
> this machine-written one: `prefs.json` is both your defaults and rio's saved state,
> so flipping a setting for one session changes your global default. For a simple
> global toggle (like wrap) that is usually exactly what you want.

**Editing modes beyond Windows.** The core ships the **Windows** editing mode only.
The **emacs** and **vi** modes install as **extensions** (`kind = mode`): add a
repository that carries them under *Settings ▸ Extensions… ▸ Repositories…* and install
from *Settings ▸ Extensions…*, or drop the module by hand into `~/.config/rio/modes/`
(a `mode` extension installs there — exactly a hand-dropped `modes/*.tcl`). Once
installed, the mode appears in *Settings ▸ Editing Mode*. If a saved `editmode` is
no longer installed, rio falls back to Windows rather than failing. The source tree
carries a ready-to-serve repository of both under `extensions/` — rsync it to a
plain-HTTP webdir and it *is* the repository.

**Your repository list, by hand.** The URLs you add under *Settings ▸ Extensions… ▸
Repositories…* are just an apt-style sources file you can edit yourself:
`$XDG_CONFIG_HOME/rio/sources.list` (default `~/.config/rio/sources.list`), **one
`http://` base URL per line**, `#` comments and blank lines allowed. The dialog reads
and writes this exact format, so hand-edits and the GUI stay in step; a hand-edit is
picked up the next time the Extensions window scans. On a **first run** rio pre-fills this
file with the project's own repository (`http://rio.skylm.org/rio`) so the Extensions window
isn't empty out of the box; remove it in *Repositories…* (or delete the line) and it stays
gone — the pre-fill happens only when the file doesn't yet exist, never on top of your edits.
Otherwise it's optional — no file means no repositories. What you've actually installed (and from where) is tracked separately in
a provenance ledger, `$XDG_DATA_HOME/rio/extensions.json` (default
`~/.local/share/rio/extensions.json`): rio writes it, and each entry records the source
URL and version a `kind/name` came from. Publishing a repository of your own is a
separate topic — see *Extension repositories* in
[CONTRIBUTING.md](CONTRIBUTING.md#extension-repositories).

### All config & data files at a glance

There is **no single `~/.riorc`**: rio follows the XDG base-directory layout and keeps
one file per concern. Two roots, split by owner — **config** (your settings, safe to
hand-edit and to keep in version control) and **data** (rio's own bookkeeping, machine-
written, not meant for hand-editing):

**Config — `$XDG_CONFIG_HOME/rio/` (default `~/.config/rio/`):**

| Path | Holds | Edit by hand? |
| ---- | ----- | ------------- |
| `prefs.json` | GUI preferences: `theme`, `wrap`, `wrap_indent`, `line_numbers`, `column_edit`, `editmode`, and the `layout` (dock) object | yes — plain JSON (above); `layout` best left to the View menu |
| `keys.json` | keyboard-shortcut **overrides** (defaults for everything you don't list) | yes (see *Keyboard shortcuts* below) |
| `sources.list` | extension-repository URLs, one `http://` base per line | yes (above) |
| `themes/` | user theme files, read by the **core** | drop-in / installed |
| `syntax/` | installed syntax highlighters (`*.tcl`) | drop-in / installed |
| `modes/` | installed editing modes — vi, emacs (`*.tcl`) | drop-in / installed |
| `agent/prompt.md` | overrides the shipped agent **base** prompt (tool contract) | yes, if you want to |

**Data — `$XDG_DATA_HOME/rio/` (default `~/.local/share/rio/`), rio-written:**

| Path | Holds |
| ---- | ----- |
| `sessions/` | per-project open files + active tab, keyed by project root (§6) |
| `extensions.json` | the provenance ledger — what's installed, from which repository, at which version |
| `secrets/*.secret` | API keys, mode `0600` (§5) — never in `prefs.json` |

**Project-local (in a project's own tree):**

| Path | Holds |
| ---- | ----- |
| `.rio/agent.md` | project-specific agent guidance, layered on top of the base prompt |

Every one of these is optional: absent means "use the built-in default." Config files
are plain text (JSON or the conf format) — **data, parsed and never executed** — and a
malformed one is skipped with a note, never fatal.

### Keyboard shortcuts

Every editor shortcut is data, remappable in **one** place. Two ways to change them:

- **The editor** — *Settings ▸ Keyboard Shortcuts…* lists every command; click a shortcut
  and press the keys you want (press-to-capture, like a modern IDE), *Clear* to unbind,
  *Default* to restore one command's original chord, or *Reset all to defaults*. **Save**
  applies immediately — no restart — and writes the file
  below for you. Conflicts and unusable keys (a lone letter, a bare modifier) are refused
  with a note.
- **By hand** — edit `$XDG_CONFIG_HOME/rio/keys.json` (default `~/.config/rio/keys.json`),
  a sibling of `prefs.json`. It is **overrides only** — list just the commands you want to
  change; everything else keeps its default. Optional (no file = all defaults), plain JSON,
  parsed never executed. A hand-edit takes effect at the next launch.

```json
{
  "close-tab": "Control-k",
  "save-as":   "Control-Shift-s",
  "quit":      ""
}
```

A value is a **chord** in Tk syntax: modifiers `Control` / `Shift` / `Alt` joined by
`-`, then the key — a letter, or a keysym like `Tab`, `backslash`, `bracketright`. An
empty string `""` unbinds the command (menu-only). The commands and their defaults:

| Command          | Default            | Does                                  |
|------------------|--------------------|---------------------------------------|
| `new`            | `Control-n`        | New tab                               |
| `open`           | `Control-o`        | Open file…                            |
| `open-folder`    | `Control-Shift-o`  | Open folder as project…               |
| `save`           | `Control-s`        | Save                                  |
| `save-as`        | `Control-Shift-s`  | Save As…                              |
| `close-tab`      | `Control-w`        | Close the current tab                 |
| `quit`           | `Control-q`        | Quit                                  |
| `undo`           | `Control-z`        | Undo                                  |
| `redo`           | `Control-Shift-z`  | Redo                                  |
| `redo-alt`       | `Control-y`        | Redo (alternate)                      |
| `next-tab`       | `Control-Tab`      | Next tab                              |
| `prev-tab`       | `Control-Shift-Tab`| Previous tab                          |
| `show-files`     | `Control-Shift-e`  | Show the files pane                   |
| `show-git`       | `Control-Shift-g`  | Show the git pane                     |
| `toggle-wrap`    | `Control-Shift-w`  | Toggle line wrap                      |
| `toggle-chat`    | `Control-Shift-a`  | Toggle the agent chat pane            |
| `split-editor`   | `Control-backslash`| Toggle the editor split               |
| `move-tab-other` | `Control-bracketright` | Move the tab to the other group   |

A capital letter in a chord implies Shift the way Tk reads it, so `Control-Shift-s` and
`Control-S` are the same binding; the menu shows either as `Ctrl+Shift+S`. If an entry
names an unknown command or a chord with a misspelled modifier, rio ignores just that
line (the rest still apply) and tells you once at startup — a bad `keys.json` never stops
the editor. Full rationale in [AGENTS.md](AGENTS.md) D23.

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
