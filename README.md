# rio

**Back to the future.** A lightweight IDE in the spirit of '90s desktop software.

- A plain-text editor with git and an AI agent. Nothing more.
- Written from scratch in Tcl/Tk. Inspired by Notepad++, Emacs and VS Code.
- Windows 2000 looks, client/server inside: edit locally or on another box.

[Website](https://rio.skylm.org/) · [User manual](docs/index.md) ·
[Changelog](CHANGELOG.md) · [Source](https://github.com/jlsksr/rio) ·
[Issues](https://github.com/jlsksr/rio/issues)

## Status

Alpha. Release **0.3.0**, 2 October 2026. Used daily by its author.

| Platform | State |
| -------- | ----- |
| Linux | Developed here. Suite passes. |
| Windows 11 | Suite passes; last run 2026-09-17. Has driven a Linux core over SSH. |
| macOS | One run, 2026-09-29: suite passes. Homebrew and MacPorts untried. |
| BSDs | Design target. Never run. |

- **Interfaces will change.** Highlighters are stable. The provider and
  editing-mode contracts are not; 1.0.0 waits for them.
- **Limitations:** [CAVEATS.md](CAVEATS.md).
- **Report** bugs, and anything that confused you.

## Install

```sh
git clone https://github.com/jlsksr/rio.git && cd rio
./install-unix.sh          # macOS: install-macos.sh   Windows: install-windows.ps1
rio [file ...]
```

- Installs Tcl/Tk, tcllib and tcltls. Adds a `rio` command, an icon and a menu entry.
- Nothing is compiled. Nothing is written outside your account.
- Server mode, Windows, troubleshooting: [INSTALL.md](INSTALL.md).

## What it does

Detail is in the [user manual](docs/index.md); `F1` opens it inside rio.

- **Editing** — tabs, undo by the word, line numbers (absolute or relative),
  optional wrap, a right-click menu. Encoding and line endings are preserved. A
  file changed on disk reloads, or asks if you have unsaved edits.
- **Recovery copies** — every changed file gets a copy outside the project,
  offered back on the next open.
  [More](docs/editor.md#keeping-your-unsaved-changes).
- **Find and replace** — `Ctrl+F`. Live highlighting, a match count; case,
  whole-word and regex toggles. Replace All is one undo step.
- **Project search** — `Ctrl+Shift+F`. The project on disk, every open document,
  or the current one. Replace works across the same scopes.
- **Split editor** — `Ctrl+\`. Two groups, each with its own tabs. Drag a tab to
  reorder it or move it across.
- **Files and git** — a project tree with create, rename and delete. Git status,
  diff, stage, unstage, commit and discard.
- **Compare view** — two documents side by side, differences coloured.
- **The agent** — a chat pane. Providers install as extensions: **Claude**, and
  **OpenAI-compatible** for ChatGPT or your own server (Ollama, llama.cpp, vLLM,
  LM Studio). Every edit and every command waits for Approve or Reject, unless
  you trusted that command. **Plan mode** only reads, then presents a plan. Its
  prompts are Markdown files on disk.
- **Syntax highlighting** — 33 languages, coloured from the theme. One file each
  in `syntax/`; override in `~/.config/rio/syntax/`.
- **Themes, fonts and keys** — themes switch live (default, Solarized Dark and
  Light, Plan 9 Acme). Pick the document font; zoom with `Ctrl+scroll`. Every
  shortcut is remappable.
- **Editing modes** — Windows built in; Emacs and vi install as extensions.
  Column editing: `Ctrl+Shift+drag`.
- **Sessions** — open files, the active tab, the unfolded tree and view
  preferences come back, per project.
- **Remote** — run the core on another box, tunnel in, then
  `rio --connect 127.0.0.1:7711 /path/on/server`. Files, git, search, the agent
  and your API key stay there.
- **Extensions** — highlighters, themes, editing modes and providers, from
  repositories you choose.

Still to come: streamed command output, the terminal frontend, packaging. See
[ROADMAP.md](ROADMAP.md).

## Extensions and repositories

- **No marketplace.** A repository is a plain directory served over HTTP or
  HTTPS, as Debian does it. Add its URL under ***Extensions ▸ Browse…***.
- **rio's own repository is pre-filled.** Remove it if you like.
- **Provenance.** Every install records its repository and version. Same name in
  two repositories: both are listed, you choose.
- **Code is called code.** Installing it says so, beside the URL you trust.
  Themes are data, never executed.
- **Signing.** A publisher signs one list of hashes with stock OpenSSH. rio
  verifies it, then every file it fetches. A new or changed key waits for your
  yes, as `ssh` does. Each extension is marked *signed*, *unsigned* or
  *unverified*.
- **Updates.** Versions are [semver](https://semver.org/). A row shows
  `[1.1.0 → 1.2.0]`. rio never updates on its own, and only from the repository
  an extension came from.
- **Publish your own:** three text files.
  [CONTRIBUTING.md](CONTRIBUTING.md#extension-repositories).

## How it is put together

```
 rio-gui (Tk)      rio-tui (Ck, deferred)      any other client
      │                    │                         │
      └──── JSONL: request · response · event ───────┘
            a pipe to a core it spawns, or a socket (--connect)
                           │
              ┌────────────┴─────────────┐
              │ rio-core  pure Tcl, no Tk│
              │ documents · undo · files │
              │ git · agent · sessions   │
              └──────────────────────────┘
```

- **All logic is in the core.** A frontend is a thin view.
- **One channel,** local or remote. No in-process path.
- **Terminal frontend:** deferred. A spike proved Ck can carry it.

## By the numbers

*Snapshot of 2026-09-26. Nothing checks these.*

- **~30,700 lines of Tcl** in 91 files: core ~9,000, GUI ~13,900, highlighters
  ~4,500; providers, modes and plugin runtime ~3,000.
- **~27,300 lines of tests**, 3,949 checks.
- **3 runtime dependencies:** Tcl/Tk, tcllib, tcltls. No build step. `tkdnd` is
  optional.
- **132 decisions**, each an [ADR](adr/README.md) with its reasoning.
- **587 commits**, 2026-06-24 to 2026-09-26, all agent-assisted. Judge it
  yourself: run the suite, read the decisions.

## Documentation

| Document | Holds |
| -------- | ----- |
| [docs/](docs/index.md) | **The user manual.** Also `F1`. |
| [INSTALL.md](INSTALL.md) | Install scripts, local and remote, troubleshooting |
| [CHANGELOG.md](CHANGELOG.md) | What changed, newest first |
| [CAVEATS.md](CAVEATS.md) | Rough edges, platform differences |
| [ROADMAP.md](ROADMAP.md) | Candidates, gaps, deferrals |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Toolchain, layout, tests |
| [adr/](adr/README.md) | Every decision and its why |
| [AGENTS.md](AGENTS.md) | Instructions for coding agents |
| [WINDOWS.md](WINDOWS.md) | rio on Windows 11 |
| [RELEASING.md](RELEASING.md) | Release gates |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | What is expected of everyone |
| [LICENSE](LICENSE) | MIT, in full |

Config is one file per concern under `~/.config/rio/`:
[reference](docs/preferences.md#where-everything-lives).

## Credits

The icon is Christ the Redeemer, for the name. Own artwork (jka, made with
ChatGPT); provenance in `rio-gui/icons/sources/README.md`.

## License

MIT, no warranty. See [LICENSE](LICENSE). Copyright © 2026 Julius Kaiser. One
licence covers the whole tree.
