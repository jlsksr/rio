# rio

A small, cross-platform IDE, **written from scratch** in Tcl/Tk: a fast,
no-nonsense text editor with first-class git and AI-agent integration — a desktop
**GUI** today, a **terminal** frontend planned, both sharing one UI-less core.

rio aims for the **sweet spot between Windows 2000-era productivity software and a
modern IDE like Visual Studio Code**: the instant start, plain menus, and
fits-in-your-head restraint of a desktop app from the era that booted before you
blinked — carrying the VSCode ideas worth keeping (split editing, side-by-side
diffs, syntax highlighting, a propose-and-approve agent) without the Electron, the
telemetry, or the plugin bazaar.

> **North star:** *VSCode's quality, with Windows 2000-era productivity-software
> discipline, in a fraction of the code, written from scratch in Tcl/Tk.* Not a
> clone — a distillation. Small feature set, small readable codebase, fast.

## Status

**rio is alpha — 0.1.0, the first release.** Real and usable, and used daily by the
person who writes it, but a long way from the full IDE, and handed to you with three
things said plainly:

- **There is no crash recovery.** A clean quit prompts you to save every modified
  buffer; a *hard* kill — a power cut, a `SIGKILL`, an X session going down — loses
  whatever was unsaved. rio does not autosave and keeps no recovery file. **Save
  often.** This is the one gap most likely to cost you real work, and it is why it is
  the first thing on this page rather than a footnote.
- **Interfaces will change.** The plugin surface especially: syntax highlighters are
  stable today, but the provider and editing-mode contracts are still settling, which
  is what **1.0.0** is reserved for. Each of those two carries a contract number, so an
  extension built against a newer rio is greyed out with a reason rather than failing
  when it loads.
- **Platforms, honestly:** Linux and Windows 11 are *run*, not assumed (see
  *Cross-platform* below). The BSDs are a design target nobody has yet sat down and
  tested. macOS is neither.

Bugs, rough edges and "this was confusing" all go to
[the issue tracker](https://github.com/jlsksr/rio/issues). Known limitations that are
deliberate live in [CAVEATS.md](CAVEATS.md).

Everything below runs today:

    wish rio-gui/rio-gui.tcl [file ...]

(needs `tclsh`/Tk + `tcllib`, plus `tcltls` for the agent's HTTPS — `./rio-dev-deploy.sh`
sets it up, or `rio-dev-deploy.ps1` on Windows; full install & deployment guide in
[INSTALL.md](INSTALL.md).)

The list below is the feature tour. For **how to use** any of it, the user manual is
in [docs/](docs/index.md).

**What works now (GUI):**

- **Editing** — open and save with encoding and line-ending (LF/CRLF)
  **preservation** (no silent rewrites), range-based editing, undo/redo a typed
  word at a time (not a keystroke at a time), several
  buffers as tabs, scrollbars, a line-number gutter (with an optional relative mode),
  current-line highlighting, a cursor-position (line/column) readout in the status bar,
  optional line wrap, and a **right-click menu** in the text (undo, the clipboard,
  select all, find/replace, and a project search seeded with the selection). A tab **notices when its file changes underneath it** — a
  `git pull`, a build, a discard: with nothing unsaved it reloads quietly (one `Ctrl+Z`
  puts back what you were looking at), with unsaved edits it asks and defaults to keeping
  them, and if the file was **deleted** it asks whether to keep the buffer open, so saving
  it later recreates the file.
- **Find & Replace** — a find bar (`Ctrl+F`, `Ctrl+H` for the replace row) with
  live match highlighting and a match count, `F3`/`Shift+F3` stepping with
  wrap-around, match-case and whole-word toggles, two-step Replace (see it selected, then
  replace it), and **Replace All as a single undo step**. The search itself runs
  in the core, so it works identically over a remote core — and any frontend
  gets it over the protocol.
- **Search** — a bottom **Search panel** (`Ctrl+Shift+F`) that finds across three scopes:
  the whole open **project** on disk, all **open documents** (reflecting unsaved edits), or
  just the **current document**. Results are grouped in a list with each hit highlighted in
  its line; double-click a match to jump to it (a disk file opens, an open document switches
  tabs). Match-case, whole-word, and **regex** toggles (line-oriented patterns with `\1`/`&`
  backreferences in replace); case-insensitive by default. A **replace row** (`Ctrl+H`)
  replaces across the same scopes — open documents in the editor (undoable), and a project-wide
  replace (confirmed first) rewrites files on disk while editing any that are open through their
  buffers, so an open view never falls out of step with the disk. The quick in-buffer find bar
  carries the same toggles and can **escalate** into the panel, taking its needle and options
  across. All matching and replacing runs in the core, so it works over the project on whichever
  box the core runs on.
- **Split editor** — show **two buffers side by side** in independent editor groups,
  each with its own tabs (`Ctrl+\` to split). **Drag tabs to reorder them within a
  group or move one across to the other group** (or use the View menu, `Ctrl+]`, or a
  tab's right-click menu). Drag the divider to resize; closing a group's last tab
  unsplits. When a window is too narrow to show every tab, **◂ ▸ arrows** page through
  them, **View ▸ *Switch to Tab…*** lists them all by name in a picker (with a path hint, so same‑named files are easy to tell apart), and **View ▸ *Multi-Line Tabs***
  wraps them onto several rows instead.
- **Files & git** — open a project folder and browse it in a side pane as an **unfoldable
  tree** — click a folder's arrow (or double-click its name) to unfold it in place and see the
  nested directories you want, fold it back to tidy up (dotfiles are
  hidden by default, like `ls`; a ◉/◌ button in the pane header — or *View ▸ Show Hidden
  Files* — reveals them); **create, rename, and delete** files and folders from the row
  menu (deletes confirm first);
  and view **git status and diffs** for the open repo with **stage, unstage,
  commit, and discard** right from the pane — *discard* puts a file back the way the last
  commit left it, **name included** (discard a rename and the file returns under its old
  name), from either pane's row menu, or the whole project at once via the **↩**
  button that appears in the git header while anything is changed (both confirm first, and
  neither touches files git ignores). The file pane keeps itself current — it updates whenever
  rio itself writes to disk (an agent edit, a discard, a project-wide replace), when rio
  regains focus, and on a manual refresh (⟳). Files
  and git share one dockable, resizable side panel. **Drag a file (or folder) from your OS
  file manager onto the window to open it** — a convenience that needs the optional `tkdnd`
  extension and a local core (see [INSTALL.md](INSTALL.md)); without it every other way to
  open a file still works.
- **Compare view** — a **side-by-side diff** of two documents, original beside
  proposed, with added/removed lines coloured and aligned (VSCode-style). Compare
  the active buffer against any file from the View menu.
- **Agent chat** — a right-hand chat column wired to pluggable providers: a
  built-in offline **echo** provider ships in the box, and real agents install from a
  repository as agent-provider extensions (*Settings ▸ Extensions…*) — **Claude** over
  the official Anthropic API, and an **OpenAI-compatible** one for hosted ChatGPT or for
  **a server of your own**: Ollama, llama.cpp, vLLM, LM Studio. Give it the server's URL
  in *Preferences ▸ Agent*, list what that machine actually has, and pick a model; your
  own server usually needs no API key at all. A thinking model's reasoning is shown in
  the chat, set apart from its answer and never sent back with it. Each provider
  brings its own API key, entered under *Preferences ▸ Agent* (a server of your own may need none). The agent lives in the core
  and runs wherever it does — so over a remote core the turn and your key stay
  server-side, with the same GUI either way (see D30). It holds a streaming
  conversation and can **read your project** (listing folders, reading files and
  open buffers — shown as it works), **propose edits**: it suggests a change or
  a new file, you review the **diff** and **Approve or Reject**, and on approval
  it applies (and, by default, saves) — and **run commands** (tests, a linter, a
  build): it proposes the exact command, you see it and **Approve or Reject**, then
  it runs, confined to your project and time-boxed. A turn runs until the model is
  done — **no step limit** — and the composer's **▶** turns into **■ Stop** while it
  works, so a turn going nowhere ends when you say so. A **complex** edit opens live in the
  side-by-side **compare view** (toggleable) rather than inline. For bigger jobs there is
  **plan mode** (*Settings ▸ Agent Mode*, or the menu atop the chat pane): the agent is
  handed no changing tools at all — it reads, then presents a **plan**, rendered as a
  document where the editor sits. **Edit** it if you want it different, then approve —
  choosing there and then whether to review each edit or auto-accept from that point. Or
  reject it and say what you want changed. Plans are kept in the project's `.rio/plans/`,
  and that file *is* the plan you approve. It is rio's own mechanism, so it
  works with whichever provider you installed. Reads run freely;
  every write waits for you (or pick *Auto-accept edits* as the mode) — and **every
  command always waits for you**, unless you mark it **trusted**: an **Always allow**
  button on the command remembers it (the program, or that exact command) so it stops
  asking — for **all projects**, **this project only**, or **only while a chosen
  provider is running**. It's standing approval you author and manage under *Preferences ▸
  Agent ▸ Allowed commands…*. You can
  **shape how it works** from *Preferences ▸ Agent ▸ Agent Prompts…*: a **system prompt** (your
  standing instructions for every project), a **project prompt** for the open folder, and
  a **per-provider prompt** applied only while a chosen provider (Claude, or an
  OpenAI-compatible model) is the one running. All open in rio's own editor and are plain
  Markdown *added on top of* rio's built-in instructions — never replacing them, and any
  may be left empty. The system and per-provider prompts live with your rio settings; the
  project prompt in a `.rio/agent.md` at the project root, so it travels with the code. The
  instructions live in rio, not the provider — so your general ones shape whichever model
  runs (Claude, ChatGPT, a model of your own), while the per-provider layer tunes just one.
  **rio's own instructions are on that same list, and you can read them** — the shipped
  base prompt and the plan-mode one, as files on disk and rendered in the app, with *Show
  the whole prompt…* for the composed text exactly as the model receives it. Nothing the
  agent is told about your project is hidden from you, and one click makes any of it your
  own editable copy. **Which model, and how hard it thinks, is a menu at the bottom of
  the pane** — provider, model, and effort in one place, with *Other…* for a model id
  the shipped list never carried and *⟳ Refresh from provider* for the models your key
  (or your local server) can actually reach. Effort defaults to sending nothing, and any
  choice that isn't the default is spelled out in the strip rather than left silently on.
  Each provider remembers its own choices in a plain file beside its prompt.
- **Theming** — live-switchable colour themes from *View ▸ Theme…*: the plain
  default, Solarized Dark/Light, Plan 9 Acme, and any theme you install or drop
  in yourself — the list is whatever the core can load. Themes are plain
  data files, never executed.
- **Editor font & zoom** — pick the document-view font family and size in *View ▸
  Font & Zoom ▸ Font…*, or zoom on the fly with **Ctrl+scroll** and **Ctrl++**/**Ctrl+-**
  (**Ctrl+0** resets). Your choice persists and overrides the theme's default.
- **Editing modes** — the text area edits like **Windows** (Notepad/VSCode:
  Ctrl+A selects all, Ctrl+V pastes) — the mode the core ships with. Two more
  install as **extensions** (below): **Emacs/readline** (Ctrl+A/E line motion,
  Ctrl+K kill, Ctrl+V really scrolls) and **vi** (modal: motions, counts,
  `d`/`c`/`y` operators, visual mode, a block cursor in normal mode). Pick one in
  *Settings ▸ Editing Mode*, remembered across runs. A mode is a small
  self-registering file in `modes/` — drop your own in `~/.config/rio/modes/` to
  replace or add one. App shortcuts (save, find, …) always win over the mode's keys.
- **Column / block editing** — Notepad++-style. Turn it on in *Settings ▸ Column
  Editing*, then **Ctrl+Shift+drag** a vertical cursor across many lines: typing,
  Backspace, Delete and Tab all act at that column on every line (one undo);
  drag a width and typing overwrites the rectangular block. Off by default.
- **Extensions & repositories** — install syntax highlighters, editing modes,
  and themes from **repositories you choose**: plain directories served over http or https,
  apt-sources style, no marketplace and no central index (see below). rio ships with
  the project's own repo (`http://rio.skylm.org/extensions`) pre-filled so there's something
  to browse on first run — remove it in *Repositories…* if you'd rather not. Browse,
  install, and remove in *Settings ▸ Extensions…*; every installed extension shows
  which repository it came from, same-name extensions from different authors
  coexist and you pick, and it all works over a remote core too. A repository can
  be **signed**, and rio checks the signature and every file against it.
- **Custom keybindings** — every shortcut is one data table. Remap them in
  *Settings ▸ Keyboard Shortcuts…* (press-to-capture, applied live, no restart) or by
  hand in `~/.config/rio/keys.json`; the menus relabel themselves to match.
- **Syntax highlighting** — colour by language, harmonised with the active theme
  (each theme carries its own `syntax.*` palette, so switching recolours code live).
  The highlighters are small, self-contained files in `syntax/` with no external
  dependencies; a language is easy to add or **swap out** — drop a replacement in
  `~/.config/rio/syntax/` to override the shipped one. **33 languages** ship:
  (X)HTML, XML, CSS, JavaScript, TypeScript, Perl, Tcl, shell, Markdown, PHP, Python,
  Ruby, Lua, C, C#, C++, Go, Rust, Java, Kotlin, Swift, Scala, SQL, JSON, YAML, TOML,
  INI, Makefile, Dockerfile, Batch, PowerShell, awk, and sed.
- **Sessions** — reopen a project and rio brings back the files you had open and the
  active tab, plus your view preferences (theme, line-wrap, dock side, chat). Even with
  **no folder open**, the loose files you had open come back too — handy for a scratch
  "daily workspace" whose files live in different places. The preferences live with the
  GUI; the open-file set lives with the project on the core, so a **remote session resumes
  too**. Both are plain data, never your API key.
- **Local & remote, one transport** — the GUI always talks to a core over a
  channel. **Locally there is nothing to start**: it spawns its own private core as
  a child process automatically. To edit on **another box**, run the core there
  (after a `git clone`: `./rio-server-deploy.sh` installs `tclsh` + `tcllib` +
  `tcl-tls`, then `tclsh rio-core/server.tcl 7711`, loopback by default), tunnel in
  (`ssh -L 7711:127.0.0.1:7711 host`), and attach:
  `wish rio-gui/rio-gui.tcl --connect 127.0.0.1:7711 /path/on/server` — or, from an
  already-open GUI, **File ▸ Connect to Remote Core…**. That tunnel is **one way in,
  not the way in**: rio speaks the protocol but never dials, so tailscale, a VPN or a
  private LAN need no support from rio — it only ever sees a `host:port`.
  Files open and save on
  whichever box the core runs on; browse them from the file tree or the point-and-click
  Open/Save dialogs, which follow the core onto the remote disk. A **stale tunnel is
  noticed within seconds** (not minutes): the GUI watches the link at the protocol
  level and tells you to re-tunnel and reconnect instead of silently hanging.

**Under the hood:** all the logic lives in a **UI-less core**, and the GUI is
**always a client** to one over a channel — a pipe to a private core it spawns
locally, or a socket to a core running elsewhere (**server mode**, like
`emacs-server`). Same op calls either way; there is no separate in-process path.
Frontends are thin views — the core owns your files and broadcasts changes back.

**Still to come:** streaming a command's output as it runs (and its own dock panel
rather than the chat), the terminal frontend (below), and a polished install/packaging
path.
The fuller list of candidate work lives in [ROADMAP.md](ROADMAP.md).

## Extensions & repositories

rio said no to the plugin bazaar — this is the yes it was saving up for. There
is **no marketplace, no store, no central index**: extensions are distributed
the way Debian distributes packages and OpenBSD serves its mirrors — you keep
a short list of **repositories**, and a repository is nothing more than a
**plain http-served directory** anyone can host with a couple of text files in
it — `https://` if you like, `http://` just as well: like a Debian source, https is
an option, not an obligation. Add a URL under *Settings ▸ Extensions… ▸ Repositories…* and everything it
carries is yours to browse and install; publishing means copying files into
your webdir, and it will still work when today's hosting fashions are gone.

No central index means no central authority — so rio doesn't pretend
otherwise. Every installed extension is marked with its **provenance** (which
repository, which version); when two repositories offer an extension of the
same name, both are listed with author and source and **you choose**; and
installing code (a highlighter, a mode) says plainly that it is code, next to
the URL you're trusting. Themes are data, parsed and never executed.

A repository can also be **signed**, and rio checks it. The publisher signs one
file listing the hash of everything they serve — two commands with stock
OpenSSH, no rio tooling — and rio verifies that signature and then every file it
fetches against it, refusing the lot if anything doesn't match. That is what
gives a plain `http://` repository integrity without a certificate: the first
time a repository signs with a key rio has no decision about, it shows you the
fingerprint and waits — the way `ssh` does — tells you if the key ever changes,
lists every key you have confirmed so you can take one back, and marks every
extension
*signed*, *unsigned* or *unverified* so you can see which you're installing. It
says these bytes are the publisher's, not that the code is any good — there is
still no authority here, and that is the point.

Versions are [semver](https://semver.org/), so rio can tell you when a
repository offers something newer — `[1.1.0 → 1.2.0]` on the row, one button to
update it, another to update everything at once, and an optional look at
start-up. **Nothing is ever installed on its own**, and an update comes only
from the repository that extension was installed from: a same-named extension
elsewhere is a different thing you may switch to, not a newer version of yours.

*Installing:* Settings ▸ Extensions…. *Publishing your own repository:* the
complete spec — three small text files — is in
[CONTRIBUTING.md](CONTRIBUTING.md#extension-repositories).

## The two faces, one brain

A Tk **GUI** (working) and a curses **TUI** over the same core — like `emacs` and
`emacs-nox`.

The **TUI is deferred**, deliberately. A throwaway spike proved the curses
toolkit (Ck) can carry it — rendering, editing, reflow, colour, and Unicode all
work — so the risk is retired, but building the terminal frontend is a separable,
later effort and isn't active work. Because every frontend speaks the same
language-neutral protocol, the TUI (or any third-party client, in any language)
can attach later **without touching the core**.

## Cross-platform

Linux (Debian, Alpine) and **Windows 11** — GUI today; the TUI when it lands. Both are
**run, not assumed**: the full suite has passed on each, and a Windows GUI has been
driven against a Linux core over an SSH tunnel, so the remote path is exercised across
platforms too ([RELEASING.md](RELEASING.md) Gate 0 records what that took, and the
handful of things still open). Development happens on Linux, so the Windows run is
periodic rather than continuous — the last was 2026-09-17. Setup on Windows is one
script — see [WINDOWS.md](WINDOWS.md).

The **BSDs** are a design target rather than a verified one: nothing in rio is
Linux-specific, the deploy scripts cover OpenBSD's `pkg_add`, and the code is the same
portable Tcl — but nobody has yet sat down and run it there, so it is listed honestly
as untested rather than claimed.

## Learn more

- **[docs/](docs/index.md)** — **the user manual**: how to actually use rio, one
  topic per page — the editor, files & projects, find & replace, git, the agent,
  preferences, keyboard shortcuts, extensions, and working over a remote core.
  Start here if you have rio running and want to know what it can do — or press
  **`F1`** (*Help ▸ Contents…*) and read it inside rio.
- **[INSTALL.md](INSTALL.md)** — install & deployment: requirements, the deploy
  scripts, local vs. remote (server mode over SSH), the agent/Claude key, and
  troubleshooting. rio keeps **no single `~/.riorc`** — one file per concern under
  `~/.config/rio/`; the
  [config & data files reference](docs/preferences.md#where-everything-lives)
  lists them all (paths, contents, which are hand-editable).
- **[CHANGELOG.md](CHANGELOG.md)** — what changed and when, newest first: features,
  improvements and fixes, each pointing at the decision behind it.
- **[AGENTS.md](AGENTS.md)** — the living design & decision log (the *why* behind
  every choice). Start here if you want the full picture.
- **[ROADMAP.md](ROADMAP.md)** — possible next steps: planned features, known gaps,
  and deliberately deferred refinements.
- **[CAVEATS.md](CAVEATS.md)** — known caveats & limitations: cross-platform behaviour
  differences (works on one OS/WM, not another) and deliberate design trade-offs, with their
  mitigations.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — for programmers who want to hack on rio
  itself: toolchain setup, how it's laid out, and how to run the tests.
- **[RELEASING.md](RELEASING.md)** — going-live checklist: the legal, first-run, and
  platform gates that must be true before rio is handed to people who didn't write it.
- **[WINDOWS.md](WINDOWS.md)** — running rio on Windows 11: one deploy script that
  installs the toolchain for you, launch, the daily notes/scratch/logfile workflow in
  keys, and a section for hacking on rio from Windows.
- **[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)** — what is expected of everyone taking
  part, and where to report it when someone falls short.
- **[LICENSE](LICENSE)** — the MIT licence, in full.

## Source, and reporting something

rio lives at **[github.com/jlsksr/rio](https://github.com/jlsksr/rio)**:

```sh
git clone https://github.com/jlsksr/rio.git
```

Found a bug, or something that surprised you? **[Open an
issue](https://github.com/jlsksr/rio/issues)** — including "this was confusing",
which is a bug in the manual and worth the same report. If it is a crash, the one
thing worth writing down is what you were doing just before it.

## License

rio is released under the **MIT License** — see [LICENSE](LICENSE) for the full
text. Use it, change it, build on it, ship it in something you sell: all of that
is fine, and the only condition is that the copyright notice and the licence text
travel with the copies you pass on. It comes with no warranty.

Copyright © 2026 Julius Kaiser. Every part of rio — the editor, the core, the
protocol, the agent loop, the highlighters, the themes, the icon — is the
project's own work, so that one licence covers the whole tree with nothing carved
out of it.
