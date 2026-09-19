# Preferences

Every setting rio keeps, what it does, and exactly which file on disk holds it.

Most settings are reachable from ***Settings ▸ Preferences…***, which gathers them
in one window; the ones you flip often also sit on the **View** and **Settings**
menus, as a second door to the same switch.

## Two kinds of saved state

rio persists two kinds of state, split by who owns it:

- **Preferences** — theme, line wrap, wrapped-line indent, line numbers, dock
  side, which panes are shown, the editor font. These are **global** and belong to
  the window, in `prefs.json` on the machine running the GUI. They load at **every**
  startup, with or without a project, so a bare `wish rio-gui/rio-gui.tcl file.txt`
  opens with your saved wrap, theme, and layout.
- **Workspace** — the files you had open in a project and which tab was active.
  This is **per-project** and belongs to the core, kept out of your source tree,
  keyed by project root. It resumes only when a **project** is open (you launched at
  a folder, or opened one); a bare file has no project, so nothing per-project comes
  back.

Neither ever holds your API key — that lives on its own, described below.

## Setting a default is just setting the value

**The last value *is* the default**, saved the moment you change it. There is no
separate "make this the default" step and no "save settings" button.

- **From the UI** — the **View** menu (Wrap Lines, Indent Wrapped Lines, Line
  Numbers, Theme…, Dock Left/Right, the pane toggles), the **Settings** menu
  (Column Editing, Editing Mode, the two agent toggles), and the shortcuts
  (`Ctrl+Shift+W` wrap, `Ctrl+Shift+A` agent pane, `Ctrl+L` line numbers). Each
  toggle rewrites `prefs.json` at once and is restored next launch.
- **By hand** — edit `prefs.json` directly. It is plain JSON, **parsed and never
  executed**:

  ```json
  {"theme":"solarized-dark","wrap":"1","wrap_indent":"1","line_numbers":"1","column_edit":"0","editmode":"windows","layout":{ }}
  ```

  | Key | Means |
  | --- | ----- |
  | `wrap` | `"1"` word-wrap on, `"0"` off |
  | `wrap_indent` | `"1"` aligns a wrapped line's continuation rows under its own indentation (visible only while `wrap` is on), `"0"` leaves them at the left margin |
  | `line_numbers` | `"1"`/`"0"` shows or hides the gutter |
  | `relative_line_numbers` | `"1"` numbers the gutter *relative to the caret* (vi-style), `"0"` counts from the top of the file |
  | `highlight_current_line` | `"1"` tints the line the caret sits on, `"0"` leaves it plain |
  | `column_edit` | `"1"` enables Notepad++-style column editing, `"0"` off |
  | `show_hidden` | `"1"` lists dot-files in the Files pane, `"0"` hides them (like `ls`) |
  | `tab_layout` | `scroll` — one row of tabs with ◂ ▸ arrows — or `multi`, wrapping them onto as many rows as they need |
  | `theme` | a name from `themes/`, or `default` |
  | `font_family` | an editor font overriding the theme's; empty means "use the theme's" |
  | `font_size` | the editor font size in points, 5–72; out-of-range values are ignored |
  | `editmode` | `windows`, `vi` or `emacs` — the last two only take effect once installed as extensions |
  | `project` | the folder that was open at the last launch, reopened on the next one (local cores only) |
  | `check_updates` | `"1"` looks for newer versions of your installed extensions shortly after start-up, `"0"` (the default) never touches the network unasked |
  | `allow_unverified_repos` | `"1"` uses a signed extension repository even where the core has no way to check its signature, `"0"` (the default) refuses it — see [below](#using-a-repository-rio-cant-check) |
  | `agent_selection_menu` | `"1"` (the default) offers **Change with Agent…** in the editor's right-click menu while a provider other than Echo is selected, `"0"` never shows it — see [the agent](agent.md#changing-just-the-selection) |
  | `layout` | a **nested object** holding the whole dock arrangement: which panes sit left, right or bottom, which are hidden, and their sizes |

  `layout` is fiddly to write by hand, so toggle it from the **View** menu and let
  rio record it. The file appears once you first change a setting (or quit), and
  you may create it by hand before the first run. Unknown or malformed keys are
  ignored, and a corrupt file is skipped rather than fatal.

> **Note.** There is not yet a *separate* hand-authored settings file distinct from
> this machine-written one: `prefs.json` is both your defaults and rio's saved
> state, so flipping a setting for one session changes your global default. For a
> simple global toggle like wrap, that is usually exactly what you want.

## Editing modes beyond Windows

The core ships the **Windows** editing mode only. **emacs** and **vi** install as
[extensions](extensions.md): add a repository that carries them under *Settings ▸
Extensions… ▸ Repositories…* and install from *Settings ▸ Extensions…*, or drop the
module by hand into `~/.config/rio/modes/` — a `mode` extension installs there, so
a hand-dropped file is exactly the same thing.

Once installed, the mode appears in *Settings ▸ Editing Mode*. If a saved
`editmode` names a mode that is no longer installed, rio falls back to Windows
rather than failing.

## Your repository list, by hand

The URLs you add under *Settings ▸ Extensions… ▸ Repositories…* are just an
apt-style sources file you can edit yourself: `sources.list`, **one base URL per
line**, `http://` or `https://`, with `#` comments and blank lines allowed. Like a
Debian source, https is an option, not an obligation: plain http is just as
supported. An https repository needs `tcltls` on the core's host — 1.8 or newer, or an
older one with [the switch under Network](#network-how-the-core-checks-https) turned on
(see [INSTALL.md](../INSTALL.md)) — and one whose certificate doesn't verify can be
[reviewed and accepted](extensions.md#a-certificate-that-isnt-trusted). A repository of
either scheme may be [signed](extensions.md#a-repository-that-is-signed), which is what
gives a plain-http one the integrity a certificate would otherwise have to provide.
The dialog reads and writes this exact format, so hand-edits and the GUI stay in
step; a hand-edit is picked up the next time the Extensions window scans.

On a **first run** rio pre-fills this file with the project's own repository
(`http://rio.skylm.org/extensions`) so the Extensions window isn't empty out of the box.
Remove it in *Repositories…* (or delete the line) and it stays gone — the pre-fill
happens only when the file doesn't yet exist, never on top of your edits.
Otherwise it's optional: no file means no repositories.

What you have actually installed, and from where, is tracked separately in a
provenance ledger, `extensions.json` — rio writes it, and each entry records the
source URL and version a `kind/name` came from, plus the fingerprint that signed it
where the repository was signed. The scheme is not part of that identity, so moving
a repository from `http://host/rio` to `https://host/rio` keeps the updates for
everything you installed from it.

## Checking for extension updates

Extension versions follow [semver](https://semver.org/), so rio can tell you when
a repository offers something newer than what you have. It compares on every scan
— opening *Settings ▸ Extensions…* rescans, as does its `⟳` button — and shows the
answer on the row: `[1.1.0 → 1.2.0]`. **Update** replaces one extension;
**Update All** takes every pending update after a single confirmation listing them.
Nothing is ever installed on its own.

An update only comes from **the repository that extension was installed from**.
Nobody owns a name — there is no central index — so a same-named extension on
another host is treated as a different thing you may *switch* to by hand, not as a
newer version of yours. Where you know better, tick *Also accept updates from other
repositories* on that extension in the Extensions window.

*Preferences ▸ Extensions ▸ Check for extension updates at start-up* (the
`check_updates` key) makes rio look once, shortly after it starts, and tell you
what it found. It is **off** by default. A version that doesn't follow semver —
a date stamp, say — is shown but never compared, and never claimed to be out of
date.

## Using a repository rio can't check

A repository can publish a **signing key**, and rio then checks every file it
fetches from it against that repository's signature — see
[extensions](extensions.md#a-repository-that-is-signed). The checking is done by
running `ssh-keygen` on the core's host, and it needs OpenSSH 8.0 or newer there —
and a core that knows about signatures at all. Where either is missing, a repository
whose key you have confirmed is **refused** rather than used unchecked.

*Preferences ▸ Extensions ▸ "Use repositories rio can't check"* (the
`allow_unverified_repos` key) lets those through anyway. It is **off** by default,
and when you turn it on such a repository lists and installs marked `unverified` —
never `signed` — and the install confirmation says so. It excuses nothing else, and
it confirms no key for you: a signature that doesn't verify, a key that changed and a
file whose hash doesn't match are refused with it on. The switch lives with the GUI,
in `prefs.json`, because it governs nothing but the Extensions window.

## The signing keys rio trusts

*Preferences ▸ Extensions ▸ Repository signing keys…* lists every signing key you
have confirmed — one row per repository, with the key's fingerprint and the date you
confirmed it, and the URL without its scheme, since `http://` and `https://` are the
same publisher. Where the core's host has no `ssh-keygen` there is no fingerprint to
show, so the row names the key itself instead. rio never adds a row on its own: a
repository that signs with a key you have not confirmed is refused until you do, from
its row in the Extensions window
([extensions](extensions.md#confirming-a-repositorys-key)).

**Forget selected** drops one, and that is a refusal rather than a tidy-up: the next
scan of that repository asks you to confirm whatever key it publishes then, and
nothing from it is listed or installed until you answer. To stop using a repository
altogether, remove it in *Repositories…*.

rio's own repository is listed `(built in)` as long as it is still in your sources —
the one key rio ships with, and the one you were never asked about. **Forget
selected** there **withdraws** it: the row stays, marked `(built in, withdrawn)`, and
rio asks about its own repository like any other's until you confirm a key for it.
Selecting either form of that row explains it in the line under the list. A window
with no rows at all means you have confirmed no keys yet, which is what it says.

The list is the file `repository-keys.conf`, beside your `sources.list`; deleting a
section there is the same thing as forgetting a key here, and a section with no `key`
line is a withdrawal — it trusts no key for that repository, not even one rio ships
with. See [extensions](extensions.md#confirming-a-repositorys-key) for what
confirming a key protects and what it cannot.

## Network: how the core checks https

*Preferences ▸ Network* holds the settings for every https connection the **core**
makes — to a hosted agent provider and to an https extension repository alike. They
are the core's, stored on the core's host, and every window attached to that core
shares them.

- ***Allow https without host-name checks (tcltls older than 1.8)*** — **off** by
  default. A `tcltls` older than 1.8 checks that a certificate comes from a trusted
  authority but never that it was issued *for the server* — any valid certificate for
  any host would pass. So on such a core, the agent and https repositories **refuse
  https** until you tick this. Tick it only on a network you trust, where `tcltls`
  can't be upgraded. It changes nothing on a `tcltls` 1.8 or newer, and plain `http://`
  is never affected. The muted line under it says which case you are in: *This core's
  tcltls checks host names, so this changes nothing here*, or the version of `tcltls`
  the core has.
- ***Accepted certificates…*** lists the certificates you accepted although they did
  not verify, with their host and port, and removes them — see
  [extensions](extensions.md#a-certificate-that-isnt-trusted).

The switch is kept in `tls.conf` in the core's config directory, as
`unchecked_hostnames = allow`. Only that line, exactly, allows: a missing file, any
other value, a line inside a `[section]` or a malformed file all mean refuse. The file
is read on every connection, so a hand edit counts without restarting the core.

## Where everything lives

There is **no single `~/.riorc`**: rio follows the XDG base-directory layout and
keeps one file per concern. Two roots, split by owner — **config** (your settings,
safe to hand-edit and to keep in version control) and **data** (rio's own
bookkeeping, machine-written, not meant for hand-editing).

**Config — `$XDG_CONFIG_HOME/rio/` (default `~/.config/rio/`):**

| Path | Holds | Edit by hand? |
| ---- | ----- | ------------- |
| `prefs.json` | GUI preferences — every key is listed [above](#setting-a-default-is-just-setting-the-value) | yes — plain JSON (above); `layout` best left to the View menu |
| `keys.json` | keyboard-shortcut **overrides** (defaults for everything you don't list) | yes — see [keyboard shortcuts](keyboard.md) |
| `sources.list` | extension-repository URLs, one `http://` or `https://` base per line | yes (above) |
| `repository-keys.conf` | the signing key you confirmed for each repository, one section per repository, written when you confirmed it | yes — delete a section to forget that key, the same as *Forget selected* in [the keys window](#the-signing-keys-rio-trusts) |
| `certificates.conf` | certificates you accepted although they did not verify, one section per `host:port` — on the **core's** host | yes — delete a section to take one back; see [extensions](extensions.md#a-certificate-that-isnt-trusted) |
| `themes/` | user theme files, read by the **core** | drop-in / installed |
| `syntax/` | installed syntax highlighters (`*.tcl`) | drop-in / installed |
| `modes/` | installed editing modes — vi, emacs (`*.tcl`) | drop-in / installed |
| `agent/prompt.md` | replaces the shipped agent **base** prompt (rio's tool contract) — an override, not a layer | only if you mean it |
| `agent/plan.md` | replaces the shipped **plan-mode** prompt (how the agent investigates and what a plan should say) — an override, not a layer | only if you mean it |
| `agent/system.md` | your **system prompt**: standing instructions added on top, for every project and provider | yes — plain Markdown |
| `agent/providers/<name>.md` | a **per-provider prompt**, applied only while that provider is live | yes — plain Markdown |
| `agent/allow.list` | trusted commands for **all projects** — one rule per line | yes — plain text |
| `agent/providers/<name>.allow.list` | trusted commands active only while that provider is live | yes — plain text |
| `agent/providers/<name>.conf` | the choices that provider remembers, such as model and effort — see [the agent](agent.md#choosing-a-model-and-how-hard-it-thinks) | yes — `key = value` |
| `tls.conf` | how the core's https connections are checked — today only `unchecked_hostnames`, on the **core's** host (see [above](#network-how-the-core-checks-https)) | yes — `key = value` |

**Data — `$XDG_DATA_HOME/rio/` (default `~/.local/share/rio/`), rio-written:**

| Path | Holds |
| ---- | ----- |
| `sessions/` | per-project open files + active tab, keyed by project root |
| `providers/` | installed agent providers — the extension kind that ships executable code, so it lives with the data, not the hand-edited config |
| `extensions.json` | the provenance ledger — what's installed, from which repository, at which version, and which key signed it |
| `secrets/*.secret` | API keys, mode `0600` — never in `prefs.json` |

**Project-local (in a project's own tree):**

| Path | Holds |
| ---- | ----- |
| `.rio/agent.md` | the **project prompt** — project-specific agent guidance, layered on top of the system prompt |
| `.rio/allow.list` | trusted commands for **this project only** |

Every one of these is optional: absent means "use the built-in default". Config
files are plain text (JSON, Markdown, or a one-rule-per-line list) — **data, parsed
and never executed** — and a malformed one is skipped with a note, never fatal.

The four `agent/` prompt files and the three allow-lists have friendly front doors
in *Preferences ▸ Agent* (*Agent Prompts…* and *Allowed commands…*); editing them
by hand and through the dialog are the same thing. The first two — the overrides —
exist only if you ask for them: *Agent Prompts… ▸ **Make my own copy…*** writes rio's
own shipped text here as your file, and rio then reads yours instead. Delete it and
rio's version comes back; you can read rio's version in that dialog either way. See
[the agent](agent.md).

## Further reading

- [Keyboard shortcuts](keyboard.md) — remapping, and `keys.json`.
- [Panels & layout](panels-and-layout.md) — what the `layout` object records.
- [INSTALL.md](../INSTALL.md) — installing and deploying rio, including where the
  agent's key and HTTPS support come from.
