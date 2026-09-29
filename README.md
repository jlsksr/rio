# rio

**Back to the future.** A lightweight IDE in the spirit of '90s desktop software.

Inspired by Notepad++, Emacs, and VS Code. Written from scratch in Tcl/Tk:
Windows 2000-era productivity aesthetic and a client/server architecture that
supports local and remote workflows.

[Website](https://rio.skylm.org/) · [User manual](docs/index.md) ·
[Changelog](CHANGELOG.md) · [Source](https://github.com/jlsksr/rio)

## Status

Alpha. The current release is **0.2.0**, 26 September 2026; `main` moves on between
releases. rio is written and used daily by its author, and is a long way from a
full IDE.

- **Linux and Windows 11 are tested, not assumed.** The suite passes on both, and
  a Windows GUI has driven a Linux core over an SSH tunnel. Development happens on
  Linux, so the Windows run is periodic rather than continuous; the last was
  2026-09-17. macOS has had one run, on 2026-09-29: the suite passes there, and
  `install-macos.sh` installs rio without root. Its Homebrew and MacPorts paths
  are untried. The BSDs are a design target nobody has sat down and run.
- **Interfaces will change.** Syntax highlighters are stable. The agent-provider
  and editing-mode contracts are still settling, which is what 1.0.0 is reserved
  for. Each carries a contract number, so an extension built against a newer rio
  is greyed out with a reason rather than failing when it loads.
- Deliberate limitations are listed in [CAVEATS.md](CAVEATS.md). Everything else
  goes to [the issue tracker](https://github.com/jlsksr/rio/issues) — including
  "this was confusing", which is a bug in the manual and worth the same report.

## Install

```sh
git clone https://github.com/jlsksr/rio.git && cd rio
./install-unix.sh          # macOS: install-macos.sh   Windows: install-windows.ps1
rio [file ...]
```

The script installs the toolchain — Tcl/Tk, tcllib, and tcltls for the agent's
HTTPS — checks that it loads, and adds a `rio` command, an icon and a menu entry.
Nothing is compiled, and nothing is written outside your own account.
[INSTALL.md](INSTALL.md) covers the rest, including server mode and Windows.

## What it does

Each line is a summary. The [user manual](docs/index.md) has the detail, and `F1`
opens it inside rio.

- **Editing** — tabs, undo a typed word at a time rather than a keystroke at a
  time, a line-number gutter (absolute or relative), current-line highlight, a
  line/column readout, optional wrap, and a right-click menu. Encoding and line
  endings are detected on open and preserved on save, so nothing is silently
  rewritten. A tab notices when its file changes underneath it — a `git pull`, a
  build, a discard — and reloads quietly, asks if you have unsaved edits, or
  offers to keep the buffer if the file was deleted.
- **Recovery copies** — rio never writes the file you are editing without a save.
  It does keep a separate recovery copy of every changed file, outside your
  project, and offers it back the next time you open that file. On by default;
  see [keeping your unsaved changes](docs/editor.md#keeping-your-unsaved-changes).
- **Find and replace** — a find bar (`Ctrl+F`) with live highlighting, a match
  count, wrap-around stepping, and match-case, whole-word and regex toggles.
  Replace All is a single undo step.
- **Project search** — a bottom panel (`Ctrl+Shift+F`) that searches the project
  on disk, every open document, or just the current one. Results group by file
  with each hit highlighted; double-click to jump to it. Replace works across the
  same scopes, and a project-wide replace edits open files through their buffers,
  so no view falls out of step with the disk.
- **Split editor** — two buffers side by side, each group with its own tabs
  (`Ctrl+\`). Drag a tab to reorder it or to move it across. When tabs outrun the
  strip, arrows page through them, a picker lists them by name, and multi-line
  mode wraps them onto several rows.
- **Files and git** — a project tree you unfold in place, with create, rename and
  delete from the row menu. Git status and diffs for the open repo, with stage,
  unstage, commit and discard. Discard puts a file back the way the last commit
  left it, name included; a button in the git header discards everything at once.
  Both confirm first, and neither touches files git ignores.
- **Compare view** — a side-by-side diff of two documents, with added and removed
  lines coloured and aligned.
- **The agent** — a chat pane wired to pluggable providers. An offline echo stub
  ships in the box; real ones install as extensions: **Claude** over the Anthropic
  API, and an **OpenAI-compatible** provider for hosted ChatGPT or for a server of
  your own (Ollama, llama.cpp, vLLM, LM Studio). It reads your project freely.
  Every edit it proposes waits for your Approve or Reject, and so does every
  command it wants to run, unless you have marked that command trusted. **Plan
  mode** hands it no changing tools at all: it reads, then presents a plan you can
  edit before approving. Model and reasoning effort are a menu at the foot of the
  pane. The instructions it runs under are plain Markdown files on disk — rio's
  own included, readable in the app — and the agent runs in the core, so over a
  remote core the turn and your key stay on the server.
- **Syntax highlighting** — 33 languages, coloured from the active theme's own
  palette, so switching themes recolours code live. Each highlighter is one
  self-contained file in `syntax/` with no dependencies; drop a replacement in
  `~/.config/rio/syntax/` to override a shipped one.
- **Themes, fonts and keys** — live-switchable themes (the plain default,
  Solarized Dark and Light, Plan 9 Acme, plus whatever you install), a document
  font you pick or zoom with `Ctrl+scroll`, and every shortcut in one data table,
  remappable in a dialog or by hand.
- **Editing modes** — the text area edits like Windows out of the box. Emacs and
  vi install as extensions, vi with motions, counts, `d`/`c`/`y` operators and
  visual mode. Column editing is Notepad++'s: `Ctrl+Shift+drag` a vertical cursor
  and type on every line at once.
- **Sessions** — reopen a project and the files you had open, the active tab, the
  unfolded tree and your view preferences come back. Loose files with no project
  open come back too, which suits a scratch workspace whose files live in
  different places.
- **Remote** — the GUI is always a client to a core over a channel. Locally it
  spawns its own core; to edit on another box, run the core there, tunnel in, and
  `rio --connect 127.0.0.1:7711 /path/on/server`. Files, git, search and the agent
  all run where the core runs, and the file dialogs follow it onto the remote
  disk. A stale tunnel is noticed within seconds rather than minutes.
- **Extensions** — highlighters, themes, editing modes and agent providers all
  install from repositories you choose. See below.

Still to come: streaming a command's output as it runs, the terminal frontend,
and a packaging path. [ROADMAP.md](ROADMAP.md) has the candidate list.

## Extensions and repositories

No marketplace, no store, no central index. Extensions are distributed the way
Debian distributes packages: you keep a short list of **repositories**, and a
repository is a plain directory served over HTTP with a couple of text files in
it. `https://` works too; like a Debian source, it is an option rather than an
obligation. Add a URL under ***Extensions ▸ Browse…***, and what that repository
carries is yours to browse and install. Publishing means copying files into a
webdir, and it will still work when today's hosting fashions are gone. rio ships
with the project's own repository pre-filled, so there is something to browse on
first run; remove it if you would rather not.

No central index means no central authority, and rio does not pretend otherwise.
Every installed extension is marked with its provenance — which repository, which
version. When two repositories offer an extension of the same name, both are
listed with their author and source, and you choose. Installing code says plainly
that it is code, next to the URL you are trusting. Themes are data, parsed and
never executed.

A repository can also be **signed**. The publisher signs one file listing the hash
of everything they serve — two commands with stock OpenSSH, no rio tooling — and
rio verifies that signature and then every file it fetches against it, refusing
the lot if anything does not match. That is what gives a plain `http://`
repository integrity without a certificate. The first time a repository signs with
a key rio has no decision about, it shows the fingerprint and waits, the way `ssh`
does; it tells you if that key ever changes, lists every key you have confirmed so
you can take one back, and marks each extension *signed*, *unsigned* or
*unverified*. A signature attests to the bytes, not to the quality of the code.

Versions are [semver](https://semver.org/), so rio can tell you when a repository
offers something newer: `[1.1.0 → 1.2.0]` on the row, a button to update one and
another to update everything, and an optional check at start-up. Nothing is ever
installed on its own, and an update comes only from the repository an extension
was installed from — a same-named extension elsewhere is a different thing you may
switch to, not a newer version of yours.

Publishing your own repository takes three small text files; the spec is in
[CONTRIBUTING.md](CONTRIBUTING.md#extension-repositories).

## How it is put together

All the logic lives in a **UI-less core**. The GUI is always a client to one over
a channel — a pipe to a private core it spawns locally, or a socket to a core
running elsewhere, like `emacs-server`. The calls are the same either way; there
is no separate in-process path. Frontends are thin views: the core owns your
files and broadcasts changes back.

That is also the room left for a **terminal frontend**, which is planned and
deferred. A throwaway spike proved the curses toolkit can carry it — rendering,
editing, reflow, colour and Unicode all work — so the risk is retired, but
building it is a separable later effort. Because every frontend speaks the same
language-neutral protocol, a TUI, or any third-party client in any language, can
attach without the core changing.

## By the numbers

*A snapshot taken 2026-09-26. rio is early, so these move; nothing checks them.*

- **~30,700 lines of Tcl** across 91 files — core ~9,000, GUI ~13,900, the 33
  highlighters ~4,500, and ~3,000 for the providers, editing modes and plugin
  runtime. No generated code, no vendored trees.
- **~27,300 lines of tests**, running **3,949 automated checks**: a core suite and
  a syntax suite under `tcltest`, 29 headless GUI suites, and one suite per provider
  plus the plugin runtime.
- **3 runtime dependencies** — Tcl/Tk, tcllib, tcltls. No build step, no
  `node_modules`, no native blobs. (`tkdnd` is optional, and only for dropping a
  file onto the window from your file manager.)
- **132 design decisions**, each written up in [AGENTS.md](AGENTS.md) with its
  reasoning and mirrored as an [architecture decision record](adr/README.md).
- **587 commits** between 2026-06-24 and 2026-09-26, all of it agent-assisted.
  Whether that worked is something you can check rather than take on trust: the
  suite runs on your machine, and the decision log records the reasoning behind
  every choice, including the ones that turned out wrong and were reversed.

## Documentation

| Document | Answers |
| -------- | ------- |
| [docs/](docs/index.md) | **The user manual** — how to use rio, one topic per page. Also `F1`. |
| [INSTALL.md](INSTALL.md) | Requirements, the install scripts, local vs. remote, troubleshooting |
| [CHANGELOG.md](CHANGELOG.md) | What changed and when, newest first |
| [CAVEATS.md](CAVEATS.md) | Known rough edges, platform differences, deliberate trade-offs |
| [ROADMAP.md](ROADMAP.md) | Planned features, known gaps, deferred refinements |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Hacking on rio: toolchain, layout, running the tests |
| [AGENTS.md](AGENTS.md) | The design log — *why* rio works the way it does |
| [adr/](adr/README.md) | The same decisions as individual records |
| [WINDOWS.md](WINDOWS.md) | Running rio on Windows 11 |
| [RELEASING.md](RELEASING.md) | The gates that must be true before a release |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | What is expected of everyone taking part |
| [LICENSE](LICENSE) | The MIT licence, in full |

rio keeps no single `~/.riorc`: there is one file per concern under
`~/.config/rio/`, and the
[config and data reference](docs/preferences.md#where-everything-lives) lists them
all — paths, contents, and which are meant to be hand-edited.

## Source, and reporting something

```sh
git clone https://github.com/jlsksr/rio.git
```

Found a bug, or something that surprised you?
[Open an issue](https://github.com/jlsksr/rio/issues). If it is a crash, the one
thing worth writing down is what you were doing just before it.

## Credits

rio's window and taskbar icon is Christ the Redeemer, for the name. It is the
project's own artwork (jka, made with ChatGPT); `rio-gui/icons/sources/README.md`
records where each icon came from and what may go in that folder.

## License

MIT — see [LICENSE](LICENSE) for the full text. Use it, change it, build on it,
ship it in something you sell. The one condition is that the copyright notice and
the licence text travel with the copies you pass on. It comes with no warranty.

Copyright © 2026 Julius Kaiser. Every part of rio — the editor, the core, the
protocol, the agent loop, the highlighters, the themes, the icon — is the
project's own work, so one licence covers the whole tree with nothing carved out
of it.
