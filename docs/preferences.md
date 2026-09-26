# Preferences

Every setting rio keeps, what it does, and which file on disk holds it.

***Settings ▸ Preferences…*** gathers them in one window. The ones you change
often are also on the **View** and **Settings** menus, as a second door to the
same switch.

**An extension's own settings are not here.** An agent provider's API key, its
server and its model belong to that extension. They are set in [a window of its
own](agent.md#a-providers-own-settings), listed by name in the *Extensions*
menu. What rio keeps *about* extensions is here, in
*Preferences ▸ Extensions*: update checking, your repository list, and the
signing keys you trust.

## What is saved where

| Kind | Holds | Kept |
| ---- | ----- | ---- |
| **Preferences** | Theme, line wrap, wrapped-line indent, line numbers, dock side, which panes are shown, the editor font. | `prefs.json`, on the machine running the window. Global: they load at every start, with or without a project. |
| **Workspace** | The files you had open in a project, and which tab was active. | With the core, outside your source tree, keyed by project root. It resumes only when a **project** is open. |

Neither ever holds your API key. That lives on its own, below.

Two settings belong to the **core** rather than to the window: how its https
connections are checked, and whether it keeps recovery copies of your unsaved
changes. Each has a file of its own on the core's host, and every window
attached to that core shares it. Both are described below.

## Changing a setting

**The last value is the default**, saved the moment you change it. There is no
"make this the default" step and no "save settings" button.

**From the window or the menus** — the **View** menu (Wrap Lines, Indent Wrapped
Lines, Line Numbers, Theme…, Dock Left/Right, the pane toggles), the
**Settings** menu (Column Editing, Editing Mode, the agent's mode), and the
shortcuts (`Ctrl+Shift+W` wrap, `Ctrl+Shift+A` agent pane, `Ctrl+L` line
numbers). Each rewrites `prefs.json` at once.

**By hand** — edit `prefs.json`. It is plain JSON, parsed and never executed:

```json
{"theme":"solarized-dark","wrap":"1","wrap_indent":"1","line_numbers":"1","column_edit":"0","editmode":"windows","layout":{ }}
```

| Key | Means |
| --- | ----- |
| `wrap` | `"1"` word-wrap on, `"0"` off |
| `wrap_indent` | `"1"` aligns a wrapped line's continuation rows under its own indentation (visible only while `wrap` is on), `"0"` leaves them at the left margin |
| `line_numbers` | `"1"`/`"0"` shows or hides the gutter |
| `relative_line_numbers` | `"1"` numbers the gutter relative to the caret (vi-style), `"0"` counts from the top of the file |
| `highlight_current_line` | `"1"` tints the line the caret sits on, `"0"` leaves it plain |
| `column_edit` | `"1"` enables Notepad++-style column editing, `"0"` off |
| `show_hidden` | `"1"` lists dot-files in the Files pane, `"0"` hides them, like `ls` |
| `tab_layout` | `scroll` — one row of tabs with ◂ ▸ arrows — or `multi`, wrapping them onto as many rows as they need |
| `theme` | a name from `themes/`, or `default` |
| `font_family` | an editor font overriding the theme's; empty means "use the theme's" |
| `font_size` | the editor font size in points, 5–72; out-of-range values are ignored |
| `editmode` | `windows`, `vi` or `emacs` — the last two only work once installed as extensions |
| `project` | the folder that was open at the last start, reopened at the next one (local cores only) |
| `check_updates` | `"1"` looks for newer versions of your installed extensions shortly after start-up, `"0"` (the default) never touches the network unasked |
| `allow_unverified_repos` | `"1"` uses a signed extension repository even where the core cannot check its signature, `"0"` (the default) refuses it — see [below](#using-a-repository-rio-cant-check) |
| `agent_selection_menu` | `"1"` (the default) offers **Change with Agent…** in the editor's right-click menu while a provider other than Echo is selected, `"0"` never shows it — see [the agent](agent.md#changing-just-the-selection) |
| `layout` | a nested object holding the whole dock arrangement: which panes sit left, right or bottom, which are hidden, and their sizes |

`layout` is awkward to write by hand. Toggle it from the **View** menu and let
rio record it.

The file appears the first time you change a setting, or when you quit. You may
create it by hand before the first start. Unknown or malformed keys are ignored,
and a corrupt file is skipped rather than fatal.

> **Note.** `prefs.json` is both your defaults and rio's saved state; there is
> no separate hand-authored settings file. Changing a setting for one session
> therefore changes your default too.

## Editing modes beyond Windows

The core ships the **Windows** editing mode only. **emacs** and **vi** install
as [extensions](extensions.md):

- add a repository that carries them with the *Repositories…* button in
  ***Extensions ▸ Browse…***, then install from that window; or
- drop the module by hand into `~/.config/rio/modes/`. A `mode` extension
  installs there, so a hand-dropped file is exactly the same thing.

Once installed, the mode appears in ***Settings ▸ Editing Mode***. If a saved
`editmode` names a mode that is no longer installed, rio falls back to Windows.

## Your repository list, by hand

The URLs you add with the *Repositories…* button are an apt-style sources file
you can edit yourself: `sources.list`, one base URL per line, `http://` or
`https://`, with `#` comments and blank lines allowed. The dialog reads and
writes that exact format, and a hand edit is picked up the next time the
Extensions window scans.

As with a Debian source, https is an option rather than an obligation; plain
http is just as supported. An https repository needs `tcltls` on the core's
host — 1.8 or newer, or an older one with [the switch under
Network](#network-how-the-core-checks-https) turned on (see
[INSTALL.md](../INSTALL.md)). One whose certificate does not verify can be
[reviewed and accepted](extensions.md#a-certificate-that-isnt-trusted). A
repository of either scheme may be
[signed](extensions.md#a-repository-that-is-signed), which gives a plain-http
one the integrity a certificate would otherwise provide.

**On a first start** rio pre-fills this file with the project's own repository,
`http://rio.skylm.org/extensions`, so the Extensions window is not empty out of
the box. Remove it in *Repositories…*, or delete the line, and it stays gone:
the pre-fill only happens when the file does not yet exist. No file means no
repositories.

What you have installed, and from where, is tracked separately in
`extensions.json`. rio writes it; each entry records the source URL and version
a `kind/name` came from, plus the fingerprint that signed it where the
repository was signed. The scheme is not part of that identity, so moving a
repository from `http://host/rio` to `https://host/rio` keeps the updates for
everything you installed from it.

## Checking for extension updates

Extension versions follow [semver](https://semver.org/), so rio can tell you
when a repository offers something newer than what you have. It compares on
every scan and shows the answer on the row: `[1.1.0 → 1.2.0]`. Opening
***Extensions ▸ Browse…*** rescans, as does its `⟳` button.

| Button | Does |
| ------ | ---- |
| **Update** | Replaces that one extension. |
| **Update All** | Takes every pending update, after one confirmation listing them. |

Nothing is ever installed on its own.

An update only comes from **the repository that extension was installed from**.
There is no central index, so nobody owns a name: a same-named extension on
another host is a different thing you may *switch* to by hand, not a newer
version of yours. Where you know better, tick *Also accept updates from other
repositories* on that extension in the Extensions window.

*Preferences ▸ Extensions ▸ Check for extension updates at start-up* (the
`check_updates` key) makes rio look once, shortly after it starts, and tell you
what it found. It is off by default. A version that does not follow
semver, such as a date stamp, is shown but never compared.

## Using a repository rio can't check

A repository can publish a signing key, and rio then checks every file it
fetches from it against that repository's signature — see
[extensions](extensions.md#a-repository-that-is-signed). The checking is done by
running `ssh-keygen` on the core's host, which needs OpenSSH 8.0 or newer there,
and a core that knows about signatures at all. Where either is missing, a
repository whose key you have confirmed is refused rather than used unchecked.

*Preferences ▸ Extensions ▸ "Use repositories rio can't check"* (the
`allow_unverified_repos` key) lets those through. It is off by default. With it
on, such a repository lists and installs marked `unverified`, never `signed`,
and the install confirmation says so.

It excuses nothing else, and confirms no key for you: a signature that does not
verify, a key that changed and a file whose hash does not match are all still
refused. The switch lives with the window, in `prefs.json`, because it governs
nothing but the Extensions window.

## The signing keys rio trusts

*Preferences ▸ Extensions ▸ Repository signing keys…* lists every signing key
you have confirmed: one row per repository, with the key's fingerprint, the date
you confirmed it, and the URL without its scheme, since `http://` and `https://`
are the same publisher. Where the core's host has no `ssh-keygen` there is no
fingerprint to show, so the row names the key itself.

rio never adds a row on its own. A repository that signs with a key you have not
confirmed is refused until you do, from its row in the Extensions window (see
[extensions](extensions.md#confirming-a-repositorys-key)).

**Forget selected** drops one, and that is a refusal rather than a tidy-up: the
next scan of that repository asks you to confirm whatever key it publishes then,
and nothing from it is listed or installed until you answer. To stop using a
repository altogether, remove it in *Repositories…*.

rio's own repository is listed `(built in)` as long as it is still in your
sources. That is the one key rio ships with, and the one you were never asked
about.
**Forget selected** there withdraws it: the row stays, marked
`(built in, withdrawn)`, and rio asks about its own repository like any other
until you confirm a key for it. Selecting either form of that row explains it in
the line under the list. A window with no rows means you have confirmed no keys
yet, and says so.

The list is the file `repository-keys.conf`, beside your `sources.list`.
Deleting a section there is the same as forgetting a key here, and a section
with no `key` line is a withdrawal.

## Recovery files for unsaved changes

rio keeps a separate copy of every changed file, and never writes the file you
are editing without a save. [The editor](editor.md#keeping-your-unsaved-changes)
describes what that means and how you get the changes back. This is where the
setting lives.

***Preferences ▸ Editor ▸ Keep recovery files for unsaved changes*** turns it on
and off. It is on by default, and this is the only place to change it.

The setting belongs to the **core**, because the copies land on the core's disk.
Every window attached to a core shares it, and over a [remote core](remote.md)
it is the server's. It is kept in `autosave.conf` in the core's config
directory, in rio's usual `key = value` format, parsed and never executed:

```
autosave    = on
interval_ms = 30000
```

- **`autosave`** — any plain way of writing no (`off`, `0`, `no`, `false`, in
  any case) stops new copies. **Anything else leaves it on**: another value, a
  typo, a malformed file, no file at all.
- **`interval_ms`** — how often a changed file is copied, in milliseconds. The
  default is 30000; below 1000 rio uses 1000. Nothing in the window sets this,
  and turning the setting off and on again leaves a hand-tuned interval alone.

`autosave` failing safe means *on*, which is the opposite of how `tls.conf`
reads a value it does not understand: there the safe side is refusing a
connection, here it is protecting work you have not saved.

Both keys are re-read before every copy, so a hand edit counts without
restarting the core. The copies live under `autosave/` in the core's data
directory, listed [below](#where-everything-lives).

## Network: how the core checks https

*Preferences ▸ Network* holds the settings for every https connection the
**core** makes: to a hosted agent provider and to an https extension repository
alike. They are stored on the core's host, and every window attached
to that core shares them.

***Allow https without host-name checks (tcltls older than 1.8)*** — off by
default. A `tcltls` older than 1.8 checks that a certificate comes from a
trusted authority but never that it was issued *for the server*: any valid
certificate for any host would pass. On such a core the agent and https
repositories refuse https until you tick this. Tick it only on a network you
trust, where `tcltls` cannot be upgraded. It changes nothing on `tcltls` 1.8 or
newer, and plain `http://` is never affected. The line under it says which case
you are in.

***Accepted certificates…*** lists the certificates you accepted although they
did not verify, with their host and port, and removes them. See
[extensions](extensions.md#a-certificate-that-isnt-trusted).

The switch is kept in `tls.conf` in the core's config directory, as
`unchecked_hostnames = allow`. Only that line, exactly, allows: a missing file,
any other value, a line inside a `[section]` and a malformed file all mean
refuse. The file is read on every connection, so a hand edit counts without
restarting the core.

## Where everything lives

There is no single `~/.riorc`. rio follows the XDG base-directory layout and
keeps one file per concern, under two roots: **config**, your settings, safe to
hand-edit and to keep in version control; and **data**, rio's own bookkeeping,
machine-written.

**Config — `$XDG_CONFIG_HOME/rio/` (default `~/.config/rio/`):**

| Path | Holds | Edit by hand? |
| ---- | ----- | ------------- |
| `prefs.json` | window preferences — every key is listed [above](#changing-a-setting) | yes — plain JSON; `layout` best left to the View menu |
| `keys.json` | keyboard-shortcut **overrides** (defaults for everything you don't list) | yes — see [keyboard shortcuts](keyboard.md) |
| `sources.list` | extension-repository URLs, one `http://` or `https://` base per line | yes (above) |
| `repository-keys.conf` | the signing key you confirmed for each repository, one section each | yes — delete a section to forget that key |
| `certificates.conf` | certificates you accepted although they did not verify, one section per `host:port` — on the **core's** host | yes — delete a section to take one back |
| `themes/` | user theme files, read by the **core** | drop-in / installed |
| `syntax/` | installed syntax highlighters (`*.tcl`) | drop-in / installed |
| `modes/` | installed editing modes — vi, emacs (`*.tcl`) | drop-in / installed |
| `agent/prompt.md` | replaces the shipped agent **base** prompt — an override, not a layer | only if you mean it |
| `agent/plan.md` | replaces the shipped **plan-mode** prompt — an override, not a layer | only if you mean it |
| `agent/system.md` | your **system prompt**: standing instructions added on top, for every project and provider | yes — plain Markdown |
| `agent/providers/<name>.md` | a **per-provider prompt**, applied only while that provider is live | yes — plain Markdown |
| `agent/allow.list` | trusted commands for **all projects**, one rule per line | yes — plain text |
| `agent/providers/<name>.allow.list` | trusted commands active only while that provider is live | yes — plain text |
| `agent/providers/<name>.conf` | what that provider remembers: the model and effort it was last set to, and whatever else it declares. For a provider that keeps [profiles](agent.md#profiles-several-setups), only which profile is live | yes — `key = value` |
| `agent/providers/<name>/<profile>.conf` | one profile of such a provider: its own model, server, limits and key — see [the agent](agent.md#settings-a-provider-declares). Per-profile files sit here too, such as the OpenAI-compatible provider's `<profile>.extra.json` | yes — `key = value` |
| `tls.conf` | how the core's https connections are checked — on the **core's** host (see [above](#network-how-the-core-checks-https)) | yes — `key = value` |
| `autosave.conf` | whether the core keeps recovery copies, and how often — on the **core's** host (see [above](#recovery-files-for-unsaved-changes)) | yes — `key = value` |

**Data — `$XDG_DATA_HOME/rio/` (default `~/.local/share/rio/`), written by rio:**

| Path | Holds |
| ---- | ----- |
| `sessions/` | per-project open files and active tab, keyed by project root |
| `autosave/` | recovery copies of changed files, each under a mirror of its own path as `#name#` — see [the editor](editor.md#keeping-your-unsaved-changes) |
| `providers/` | installed agent providers — the extension kind that ships executable code, so it lives with the data rather than the hand-edited config |
| `extensions.json` | what is installed, from which repository, at which version, and which key signed it |
| `secrets/*.secret` | API keys, mode `0600` — never in `prefs.json` |

**Project-local, in a project's own tree:**

| Path | Holds |
| ---- | ----- |
| `.rio/agent.md` | the **project prompt**, layered on top of the system prompt |
| `.rio/allow.list` | trusted commands for **this project only** |

Every one of these is optional: absent means "use the built-in default". Config
files are plain text: JSON, Markdown, or one rule per line. They are parsed and
never executed, and a malformed one is skipped with a note rather than being
fatal.

The four `agent/` prompt files and the three allow-lists have front doors in
*Preferences ▸ Agent* (*Agent Prompts…* and *Allowed commands…*); editing them
by hand and through the dialog are the same thing. The two overrides exist only
if you ask for them: *Agent Prompts… ▸ Make my own copy…* writes rio's shipped
text here as your file, and rio then reads yours. Delete it and rio's version
comes back. See [the agent](agent.md).

## Further reading

- [Keyboard shortcuts](keyboard.md) — remapping, and `keys.json`.
- [Panels & layout](panels-and-layout.md) — what the `layout` object records.
- [INSTALL.md](../INSTALL.md) — installing and deploying rio.
