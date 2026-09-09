---
title: rio
description: A small, language-agnostic IDE in Tcl/Tk — client-server, network-transparent, plain-data config, no bloat.
---

# rio

**A small, language-agnostic IDE. Tcl/Tk, client-server, no bloat.**

Written **from scratch** — no framework, no fork, no Electron. rio aims for the
**sweet spot between Windows 2000-era productivity software and a modern IDE like
Visual Studio Code**: menus and panes you already know, from an app that starts
instantly and never phones home — carrying the ideas worth keeping from VSCode (a real
editor, real git, an AI-agent workflow) in one readable codebase that edits any
language.

## Highlights

- **From scratch, and small.** Editor, git, diff view, agent loop, wire protocol —
  all rio's own code. About 9,000 lines of Tcl; you can read the whole thing.
- **The sweet spot.** Windows 2000-era discipline — instant start, a menu bar, a
  feature set that fits in your head — with the VSCode ideas worth keeping: split
  editing, side-by-side diffs, syntax highlighting, a propose-and-approve agent.
- **Three dependencies.** Tcl/Tk, tcllib, tcltls — no build step, no `node_modules`,
  no native blobs.
- **Network-transparent.** The GUI is always a client to a *core*; the core runs here
  or on another box. Same UI either way — your files live wherever the core does.
- **Pipes locally, SSH remotely.** No listening socket, no auth to configure; the
  core never faces the network itself. Remote is what SSH is already for.
- **Config is data, never code.** Themes, keybindings, highlighters, the agent's
  prompt — plain files you can read, edit, and override under `~/.config/rio`.
- **Language-agnostic.** An editor, not a Java/JS-specific IDE. Open any file.
- **Cross-platform.** Linux, the BSDs, Windows — anywhere Tcl runs. (Terminal
  frontend later.)

## What rio does today

Every item below runs now, in the GUI:

- **Editing** — open and save with **encoding and line-ending (LF/CRLF) preservation**
  — no silent rewrites. Range-based edits, undo/redo, tabbed buffers, optional wrap.
- **Split editor** — two buffers **side by side** in independent groups, each with its
  own tabs (`Ctrl+\`). **Drag tabs to reorder or move one across** (or the View menu /
  a tab's right-click menu); drag the divider to resize; the last tab closing unsplits.
- **Files & git** — open a project folder, browse it in a dockable side pane with
  New / Rename / Delete, and work the repo: **git status, diffs, stage/unstage, and
  commit** from the GUI, with the file pane flagging each file's git state.
- **Compare view** — a **side-by-side diff** of two documents, added/removed lines
  coloured and aligned, VSCode-style.
- **AI agent** — a chat column wired to an offline **echo** provider and to **Claude**
  over the official Anthropic API (bring your own key). It streams, **reads your
  project** (folders, files, open buffers — shown as it works), and **proposes edits**
  you review as a **diff** and **Approve or Reject** — reads run freely, every write
  waits for you. The agent lives in the core, so over a remote core your key and its
  HTTPS never leave the server.
- **Theming** — live-switchable themes (plain default, Solarized Dark/Light, Plan 9
  Acme) — plain data files, never executed, so loading one runs no code.
- **Custom keybindings** — every shortcut is one data table. Remap in a press-to-capture
  editor (applied live, no restart) or by hand in `keys.json`; menus relabel to match.
- **Syntax highlighting** — 33 languages, colour harmonised with the active theme.
  Each highlighter is one self-contained Tcl file (per-line scan, ~150 lines) — **no
  tree-sitter blob, no language server, no build**; the text widget already tokenizes.
  Drop one in `~/.config/rio/syntax` to override the shipped version or add a language.
  Shipped: (X)HTML, XML, CSS, JavaScript, TypeScript, Perl, Tcl, shell, Markdown, PHP,
  Python, Ruby, Lua, C, C#, C++, Go, Rust, Java, Kotlin, Swift, Scala, SQL, JSON, YAML,
  TOML, INI, Makefile, Dockerfile, Batch, PowerShell, awk, and sed — rio highlights its
  own source.
- **Editing modes** — pick **Windows**, **Emacs/readline**, or **Vi** key behaviour
  (Settings ▸ Editing Mode). The core ships Windows; Emacs and Vi install as extensions.
- **Find & Search** — an in-buffer find/replace bar (regex, whole-word) and a project-wide
  **Search panel** that unifies find-in-files with open-buffer search, replace across
  scopes, and regex — results in a dockable bottom pane.
- **Line numbers, wrap-indent & column editing** — a line-number gutter, a Ln/Col
  indicator, wrapped-line indentation, and Notepad++-style vertical **column/block
  editing** (Ctrl+Shift+drag a caret down many lines, then type).
- **Dockable tool panes** — Files, Git, Agent, and Search live in left / right / bottom
  docks; relocate any pane by right-click or by dragging its tab, and hide any of them
  entirely — down to a bare editor if you want one.
- **Extensions & repositories** — install syntax highlighters, editing modes, and themes
  from plain-`http://` **repositories you choose** (the apt-sources model: no store, no
  central index). Every install is marked with its provenance.
- **Sessions** — reopen a project and rio restores the open files, active tab, and view
  preferences. Preferences live with the GUI, the open-file set with the project on the
  core, your key with neither — so a **remote session resumes too**.
- **Local *or* remote, one transport** — locally there's nothing to start (the GUI
  spawns its own private core); to edit on another box, run the core there and attach
  over SSH. Same UI, same ops, either way.

## Architecture

Three pieces, one protocol:

- **core** — UI-less. Owns your files, git, undo, and the agent loop. Speaks a small
  JSON-line protocol over a channel: a pipe locally, a socket over SSH remotely.
- **GUI** — a thin Tk view. It renders and sends keystrokes as ops; it never touches
  your files directly. The core broadcasts every change back.
- **TUI** — a curses frontend over the same core. Prototyped, deferred.
- **plugins** — e.g. the Claude provider. The protocol is language-neutral, so a
  frontend or client can be written in anything.

Frontends are dumb views, so "remote" comes for free: run the core on a server, attach
a GUI over SSH, edit as if local. The agent runs *in the core*, so with a remote core
your API key and its HTTPS stay server-side.

## By the numbers

- **~15,800 lines of Tcl**, across 72 files — core ~4,000, GUI ~6,600, 33 highlighters
  ~4,500, plugins + modes ~680. No generated code, no vendored trees.
- **~10,400 lines of tests** — **1,859 automated cases**: a core and a syntax suite
  (tcltest) plus 14 headless GUI suites. The tests run about two-thirds the size of the
  app they cover.
- **3 runtime dependencies.** Tcl/Tk, tcllib, tcltls.
- **52 design decisions**, each written down in [AGENTS.md](AGENTS.md) — the *why*
  behind every choice, not just the *what*.
- **Built in ~2 months** (2026-06-24 → 2026-08-20), 236 commits, entirely
  agent-assisted.

## Quickstart (local)

```sh
git clone <repo> rio && cd rio
./rio-dev-deploy.sh            # tcl, tk, tcltls, tcllib, git
wish rio-gui/rio-gui.tcl .     # open the current dir as a project
```

Nothing else to start — the GUI spawns its own core.

## Remote (the gist)

```sh
# on the server:
./rio-server-deploy.sh && tclsh rio-core/server.tcl 7711      # loopback only

# on your machine:
ssh -NL 7711:127.0.0.1:7711 you@server
wish rio-gui/rio-gui.tcl --connect 127.0.0.1:7711 /path/on/server
```

SSH does the auth and crypto; the core never faces the network itself. Full recipe in
[INSTALL.md](INSTALL.md).

## Why

rio is, openly, a vibe-coding experiment — a test of whether agent-assisted
development could carry something bigger than a self-contained script: a real,
multi-part application, kept honest by the test suite and the decision log. It is also
an itch. Good editors are worth loving; most have grown heavy, and day to day you
reach for maybe 5% of VSCode, Emacs, or Notepad++. rio is that 5%, built small on
purpose — a tailored editor rather than a general one, and honest about being early.

## Status

Early but real — editing with encoding/EOL preservation, tabbed buffers, a split
editor with draggable tabs, git (status, diffs, stage/commit), a side-by-side compare
view, project-wide search, dockable tool panes, theming, 33-language syntax
highlighting, editing modes, an extension/repository system, the agent (read +
propose-edit), and a local *or* remote core all work today. The terminal (curses)
frontend is the next big piece.

See [README.md](README.md) for the feature list, [INSTALL.md](INSTALL.md) to deploy,
[AGENTS.md](AGENTS.md) for the design log.

## Changelog

A curated history of the noticeable changes — features, improvements, and fixes —
newest first. It is **not** every commit: each entry cites its design decision
(*Dnn*, written up in [AGENTS.md](AGENTS.md)), a representative commit, and the date.

rio is also an experiment. The interesting question behind it is whether an AI agent can
carry a *complex* application — an IDE, not a script — in a language the mainstream
mostly skips (**Tcl/Tk**), under deliberately **opinionated, Windows-2000-era** design
constraints, and keep it honest with a real test suite and a written decision log.
Everything below was built end to end that way, agent-assisted, in about two months.

### September 2026

- **Browse your project as an unfoldable tree** — the Files pane used to show one directory at
  a time: to look inside a folder you replaced the whole view with its contents, then climbed
  back out with a `..` row. Now it's a tree rooted at your project — click a folder's little
  arrow (or double-click its name) and it *unfolds in place*, its contents nested right
  underneath, so you can open up just the branches you care about and see several levels at
  once. Fold it back to tidy up; the twisty (▸/▾) shows what's open. Creating a file in a
  folder unfolds it for you, and the git-status flags ride along at every depth. — *feature ·
  D87 · `be43197` · 2026-09-09*
- **Drag a file onto the window to open it** — grab a file (or a whole folder, or several at once)
  in your OS file manager and drop it anywhere on the rio window — the editor, a side pane, the tab
  strip — and it opens, just as you'd expect from any editor. It rides on the optional `tkdnd`
  extension (install it once; rio runs fine without it, drag-to-open simply stays off) and works
  with a local core, since a dropped file lives on your own machine. — *feature · D86 · `ed682cd` · 2026-09-09*
- **Agent settings gathered in one place** — the top-level *Settings* menu now keeps only the two
  quick agent switches you flip mid-task — **which provider is live** and the edit toggles — while the
  agent's real configuration (its **API key**, its **prompts**, its **trusted-command list**) moved
  into the **Preferences** window's Agent pane, where a settings window can grow without cramming the
  menubar. One home, one place to look. — *housekeeping · D85 · `5205f6c` · 2026-09-09*
- **Trust a command so it stops asking** — when the agent proposes a command, the approve bar now
  offers **Always allow**: remember the **program** (every `pytest` from now on) or just **that exact
  command**, and choose how far the trust reaches — **all projects**, **this project only**, or
  **only while a particular model is running**. rio runs it next time without stopping you. It's an
  **opt-in** list *you* write — standing permission, not the agent going off on its own — managed
  under *Preferences ▸ Agent ▸ Allowed commands…* (or edited by hand). Everything else still waits for
  you, and a trusted command is still run the safe way — no shell, confined to your project,
  time-boxed. The bar you approve once becomes the bar you never see again. — *feature · D84 · `e566586` · 2026-09-09*
- **The agent can run commands** — ask it to run your tests, a linter, or a build, and it
  proposes the **exact command**; you see it and **Approve or Reject** before anything runs. A
  command **always** waits for you — even with *Auto-accept edits* on — runs **confined to your
  project**, and is **time-boxed** so nothing hangs the editor. No shell, no surprises: rio runs the
  literal command you approved. — *feature · D83 · `9f6a688` · 2026-09-09*
- **The agent's "working" indicator** — while the agent is thinking, the chat status line
  cheerfully cycles vintage loading messages ("Reticulating splines…", "Defragmenting…") so a
  wait never looks like a freeze. — *feature · D82 · `946e6ae` · 2026-09-09*
- **Longer commit messages** — the Git pane's commit box now has a **＋** to add a multi-line
  description under the summary line, so a bigger change can carry a proper explanation instead
  of just a one-liner. — *feature · D81 · `e7e2f43` · 2026-09-08*
- **Discard your changes** — right-click a changed file in the Git pane to throw your edits
  away: **Discard Changes…** returns a tracked file to its last committed version, **Delete…**
  removes a brand-new file — each behind a one-click confirm. — *feature · D80 · `0a82d64` ·
  2026-09-08*
- **Per-provider agent instructions** — alongside your all-projects and per-project prompts,
  you can now write instructions that apply *only* while a particular provider is running —
  Claude-specific quirks, or house rules for a local OpenAI-compatible model. Editable from
  Preferences ▸ Agent ▸ Agent Prompts…; the agent stays entirely optional. — *feature · D79 · `a66c737` ·
  2026-09-08*
- **Multi-line tabs, tightened** — in multi-line tab mode each row now packs its tabs at
  their natural width and justifies to fill the strip, so a short tab no longer inherits a
  long tab's column and nothing is clipped off the right edge. — *fix · D78 · `e5d12da` ·
  2026-09-08*
- **Open several files at once** — the Open dialog takes a Ctrl/Shift multi-selection and
  opens every picked file. — *improvement · D77 · `ef53df6` · 2026-09-08*
- **Help ▸ About rio** — a Help menu with an About window showing the build's commit id and
  date. — *feature · D76 · `658df39` · 2026-09-08*
- **Find menu** — the search cluster (Find, Replace, Find in Files…) gets its own top-level
  menu. — *improvement · D75 · `3424c34` · 2026-09-08*
- **Compare against an open tab** — Compare is its own top-level menu, and you can now diff
  the current file against any other open tab through a shared buffer picker (the old
  per-buffer Tabs menu retired). — *feature · D73/D74 · `ac5242d` · 2026-09-08*
- **Anonymous workspace** — opening loose files with no project is now a real, resumable
  session: reopen rio and the same files come back. — *feature · D72 · `e912cb8` ·
  2026-09-08*
- **Relative line numbers** — a hybrid vim-style gutter modifier: the current line shows its
  absolute number, the rest show their distance from it. — *feature · D71 · `e7f08f3` ·
  2026-09-05*
- **A home for the agent's prompts** — the agent's system prompt ships as an editable
  `agent/prompt.md`, with an optional per-project `.rio/agent.md` layer on top. — *feature ·
  D70 · `6d1e38f` · 2026-09-04*
- **LLM providers are installable plugins** — ChatGPT and Claude both now install from an
  extension repository like any other extension; the core ships only the offline `echo`
  stub built in. Add a provider by pointing rio at a repository, installing it, and
  restarting. — *feature · D66/D69 · `c15ae1c` · 2026-09-04*
- **A second LLM provider (OpenAI-compatible)** — talk to hosted ChatGPT, or point its base
  URL at a local OpenAI-compatible server (Ollama, llama-server, …) to run a local model;
  the provider contract was hardened so it could carry a second implementation. — *feature ·
  D65 · `615172b` · 2026-09-04*
- **Extensions… moves to Settings** — the Extensions manager now sits under Settings, beside
  Preferences…, rather than in the View menu. — *improvement · D67 · `13b77fc` · 2026-09-04*
- **View menu fits on screen** — the View menu is grouped into submenus so it never runs off
  a short display. — *improvement · D64 · `223fa89` · 2026-09-04*
- **Tooltips on glyph controls** — the bare-glyph header buttons (⟳, hidden-files, …) show
  hover tooltips naming what they do. — *improvement · D63 · `d45c215` · 2026-09-04*
- **Hide dotfiles** — the Files pane hides dotfiles by default (like `ls`), with a ◉/◌
  toggle in its header. — *improvement · D62 · `bcd591b` · 2026-09-04*
- **Click a gutter number** — click a line number to select its whole line, drag to extend
  the selection. — *improvement · D61 · `bb55728` · 2026-09-04*
- **Current-line highlight** — the caret's line is highlighted, on by default and
  toggleable. — *feature · D60 · `a9204a9` · 2026-09-04*
- **Central Preferences window** — one Preferences window gathers settings (theme, editor
  font, toggles) that were scattered across menus; it owns no state of its own. — *feature ·
  D58 · `b7650f5` · 2026-09-03*
- **Tab-strip overflow handling** — when tabs outrun the strip, page them behind ◂ ▸ arrows
  (the default), or wrap them onto several rows, plus a Switch-to-Tab picker that lists them
  all. — *feature · D57 · `bba3078` · 2026-09-03*
- **Editor font picker + zoom** — choose the editor font family and size, and zoom in and
  out, as a user override layered over the theme. — *feature · D56 · `38501a3` · 2026-09-03*
- **Windows support** — rio runs on Windows: source files are read as UTF-8 everywhere (no
  more mojibake glyphs), and the core answers host questions so a remote frontend never
  guesses the wrong path rules. — *fix · D54/D55 · `508f4e9` · 2026-09-03*

### August 2026

- **Line-number gutter repaint fix** — the gutter now repaints on edits that add or
  remove lines and on tab switches, not only when the view scrolls. — *fix · D49 ·
  `cf424b6` · 2026-08-20*
- **Per-pane show/hide** — every tool pane (Files, Git, Agent, Search) can be hidden
  entirely, down to a bare editor; a dock collapses when its last pane is hidden, and the
  View menu toggles each. — *feature · D35 · `eea9676` · 2026-08-20*
- **Column-editing caret polish** — the multi-line block caret is a thin blinking bar on
  every line, and the toggle is greyed out except in Windows editing mode. — *improvement
  · D40 · `5a95e65` · 2026-08-20*
- **Dockable tool-window system** — Files / Git / Agent / Search sit in left, right, and
  bottom docks with host-owned tab strips; relocate a pane by right-click "Move to" or by
  dragging its tab, with no window flicker on a tab swap. — *feature · D35 · `48f8656` ·
  2026-08-20*
- **Search panel** — find-in-files and open-buffer search unified in one bottom panel,
  with replace across scopes and regex on every surface. — *feature · D52 · `34d8b6c` ·
  2026-08-19*
- **Find in Files** — a core `project.search` with a bottom results panel; whole-word
  option and per-hit highlighting. — *feature · D51 · `25a752f` · 2026-08-19*
- **Cursor position** — a live Ln/Col indicator in the status bar. — *feature · D50 ·
  `2ce889e` · 2026-08-19*
- **Line-number gutter** — an optional gutter down each editor group. — *feature · D49 ·
  `acefe91` · 2026-08-19*
- **File management** — New / Rename / Delete from the file pane's context menus. —
  *feature · D48 · `5315a28` · 2026-08-18*
- **File-pane auto-refresh** — the tree updates when files change on disk outside a buffer
  (e.g. an agent write), with a manual ⟳ and an on-focus refresh. — *improvement · D47 ·
  `5728334` · 2026-08-18*
- **Git commit from the GUI** — an auto-showing commit bar; the first inline pane input. —
  *feature · D45 · `76bea36` · 2026-08-07*
- **Git write ops + pane context menus** — stage / unstage / track from right-click menus
  on the file and git panes. — *feature · D44 · `3df70cd` · 2026-08-07*
- **Rich file & git panes** — both panes become text-widget rich-lists, and the file pane
  flags each file's git state. — *improvement · D42/D43 · `3cde0a4` · 2026-08-06*
- **Syntax highlighting → 33 languages** — added Ruby, SQL, YAML, TOML, Java, Kotlin,
  Swift, Scala, TypeScript, XML, INI, Makefile, Dockerfile, Batch, PowerShell, awk, and
  sed, with whole-name registry matching. — *feature · D32/D46 · `8e8dd83` · 2026-08-09→10*
- **Emacs & Vi unbundled as extensions** — the core ships Windows mode only; emacs and vi
  install from a repository like any other extension. — *improvement · D41 · `c1be851` ·
  2026-08-03*

### July 2026

- **Column / block editing** — a Notepad++-style vertical, multi-line cursor. — *feature ·
  D40 · `99a07f3` · 2026-07-23*
- **Indent Wrapped Lines** — align a paragraph's wrapped rows under its own indent; Tab
  block-indents the selection in Windows mode. — *improvement · `a0b323d` · 2026-07-23*
- **Monochrome-glyph iconography** — the modified dot, find arrows, send, and refresh
  glyphs (the D27 sweep). — *improvement · D27 · `2019c19` · 2026-07-23*
- **Extension repositories** — install highlighters, modes, and themes from plain-`http://`
  repositories you add yourself (the apt-sources model: no store, no central index), with
  an Extensions window and provenance tracking. — *feature · D39 · `e0f59b0` · 2026-07-22*
- **Editing modes** — Windows / Emacs / Vi as a bind-tag layer. — *feature · D38 ·
  `ea94992` · 2026-07-12*
- **Find / Replace** — a search engine in the core with an in-buffer find bar. — *feature ·
  D36 · `a8bc970` · 2026-07-12*
- **Dock-site system (first cut)** — tool windows get a real dock instead of chat-as-buffer.
  — *feature · D35 · `16ab10a` · 2026-07-12*
- **Stale-link watchdog** — a dead SSH tunnel is detected in seconds, not minutes. — *fix ·
  D37 · `eed9bfc` · 2026-07-12*
- **Configurable keybindings** — every shortcut is one data table, remappable live in a
  press-to-capture editor or by hand in `keys.json`. — *feature · D23 · `a0cb75b` ·
  2026-07-08*
- **Agent system prompt** — a core-owned, provider-agnostic prompt, layerable per project
  via `.rio/agent.md`. — *improvement · D34 · `8378cf4` · 2026-07-08*
- **Split editor** — two buffers side by side in independent groups; drag tabs to reorder
  within a group or move across, plus a right-click tab menu. — *feature · D33 · `7bcfe78` ·
  2026-07-06→07*
- **Syntax highlighting engine** — swappable per-line tokenisers and the first 16 languages
  (HTML, CSS, JS, Perl, Tcl, shell, Markdown, PHP, Python, Lua, C, C#, C++, Go, Rust, JSON).
  — *feature · D32 · `5195c91` · 2026-07-01→11*
- **Sessions & preferences** — resume the open files, active tab, and view prefs; a remote
  session resumes too. — *feature · D31 · `2bd6372` · 2026-07-01*
- **Remote from a running GUI** — File ▸ Connect to Remote Core…, with point-and-click
  remote file browsing. — *feature · D30 · `4bbda06` · 2026-07-01*

### June 2026

- **One channel transport** — the GUI always spawns or attaches a core over a channel (pipe
  locally, socket remotely); the in-process path retired, and the agent moved onto the
  channel so a remote core keeps your key and its HTTPS server-side. — *improvement · D30 ·
  `ff4dc93` · 2026-06-30*
- **Edit over a remote core** — the GUI as a socket client, failing gracefully when the core
  is unreachable, plus the slim `rio-server-deploy.sh`. — *feature · D29 · `c4f6ddf` ·
  2026-06-30*
- **Compare / diff view** — a side-by-side diff of two documents, added and removed lines
  coloured and aligned. — *feature · D28 · `086654f` · 2026-06-29*
- **AI agent** — a streaming `agent.*` protocol and chat pane, the Claude provider over the
  official Anthropic API, read-only file tools, and a propose-and-approve edit gate (reads
  run freely; every write waits for you). — *feature · D26 · `48f58f9` · 2026-06-27→28*
- **Files & git side dock** — a resizable dock hosting the file browser and a git
  status / diff / log pane. — *feature · D7 · `21cc63a` · 2026-06-27*
- **Theming as plain data** — semantic, live-switchable themes that execute no code:
  default, Solarized Dark/Light, Plan 9 Acme. — *feature · D24 · `d59e105` · 2026-06-26*
- **Core foundation** — the UI-less document model and dispatch, `buffer.*` / `fs.*` ops with
  encoding and LF/CRLF preservation, per-buffer undo/redo, a socket transport, and
  `session.hello` negotiation. — *feature · D22 · `0199abc` · 2026-06-25*
- **A real Tk frontend** — wired to the core across the protocol seam. — *feature ·
  `17cbadd` · 2026-06-25*
- **Project start** — the AGENTS.md decision log and the initial design docs, followed
  the next day by the protocol-seam spike (`461986f`) proving the core⟷frontend bet. —
  *`7a97d46` · 2026-06-24*
