# AGENTS.md — rio

## Instructions for agents

*(jka, 2026-10-02. These outrank everything below.)*

- **Few words.** Anything a human reads (comment, commit message, reply, document):
  as few words as possible, each one chosen. To the point. No agent prose.
- **Comment the block.** A small comment saying *what* it does and *why*. Examples
  where possible. ASCII drawings for complex systems.
- **Don't waste RAM.** KISS/UNIX/POSIX. rio must run on small systems: a Raspberry
  Pi, a cheap VPS, old Linux hardware.
- **Code for humans.** Readable over clever.
- **Maintain these files:**
  - `adr/` — architecture decision records
  - `AGENTS.md`
  - `CAVEATS.md`
  - `CHANGELOG.md` ([Keep a Changelog](https://keepachangelog.com/))
  - `CONTRIBUTING.md` — for humans first
  - `DOCS.md` — not too early; let concepts grow first. Later elaborated into `docs/`.
  - `README.md` — no prose; first presence, overview for humans
  - `ROADMAP.md`
- **Idempotent scripts.** Every administration, deployment or install script.
- **[Semantic versioning](https://semver.org/).**

## What rio is

A plain-text editor with git and an AI agent, and nothing more. *VSCode's quality,
90s discipline, a fraction of the code, in Tcl/Tk.*

- **In:** editing, git, the agent, tabs and side panes, a GUI, a remote core,
  extensions from plain HTTP repositories.
- **Out:** per-language IDE features (LSP), any terminal pane, a marketplace,
  collaborative editing, unattended agents.
- **Deferred:** the terminal frontend (Ck), the general plugin platform.
- **The test for a feature:** would the 5% of an editor you use every day miss it?

## Architecture

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
              └────────────┬─────────────┘
                           │ provider-api
              providers (installed extensions)
```

- **Logic lives in the core.** A frontend is a dumb view: input becomes an op, and
  the screen changes when the core's event comes back (D1, D3).
- **One channel.** No in-process path (D30).
- **The agent runs in the core.** Tools and the system prompt are the core's; a
  provider only talks to its model (D20, D26).
- **Config is data.** Parsed, never executed (D21, D24).

## Rules

- **Tcl only.** No Python, not even a scratch script.
- **New behaviour is an op** in `rio-core`, shaped for a terminal client: structured
  data, never Tk-shaped.
- **Headless code is Tk-free and calls `exit`.** Tk makes a bare `tclsh` hang at EOF.
- **Ask, don't assume.** A fact about the core's host: ask the core (D55). A fact
  about the platform: ask Tk (D133).
- **Dependencies:** Tk + tcllib for the GUI; Tcl + tcllib + tcltls for the core. An
  optional one must be safe when absent (ADR-0115).
- **The agent assists; it never acts unattended** (D53). Sanctioned APIs only (D26).
- **Versions:** semver for a release, an integer for a contract (D123).
- **UI:** Win2000 and VSCode are the bar. Icons are monochrome Unicode glyphs (D27).
  Help text must not look like a control (D68).

## How we work

- **Evaluate before coding.** Name the seam, the effort and the bloat risk. Get a go
  before a large change.
- **Change is earned.** "Clean" is a valid finding.
- **Generalize.** Never add a parallel copy.
- **Phases.** Each leaves every suite green and is its own commit.
- **Git.** Branch large work, merge `--no-ff` when green. Small fixes go to `main`.
  Commit every verified step. Never push; jka pushes.
- **Tests are the evidence** (ADR-0116). No network. A test that spends tokens needs
  permission each time. Prove a new check by breaking what it guards.
  Commands: [CONTRIBUTING.md](CONTRIBUTING.md).
- **Report faithfully.** A failure with its output; a skipped step by name.
- **Ask rarely.** Only what jka alone can decide; lead with a recommendation.
- **Confirm first** before anything irreversible or outward-facing.

## Documents

| File | Holds |
| ---- | ----- |
| `adr/` | Every decision and its why. A new one: [adr/README.md](adr/README.md). |
| `CHANGELOG.md` | What a user can see changed. Each entry cites its decision. |
| `ROADMAP.md` | Candidates and open questions. Keep it pruned. |
| `CAVEATS.md` | Rough edges; "works here, not there". |
| `INSTALL.md` | Install and deployment. Other files only point to it. |
| `CONTRIBUTING.md` | For a human sending a patch. |
| `docs/` | The user manual. `DOCS.md` is its maintainer's guide. |
| `README.md` | First presence. |

`Dnn` in a comment or the changelog names a decision: D1 to D111 are ADR-0001 to
ADR-0111, the rest are in [adr/README.md](adr/README.md).

## Derived-facts register

A fact with two homes rots unless a test holds them together (ADR-0117).

- A new copy gets a row and a guard.
- Guard behaviour, not source text.
- Check both directions.
- A row without a guard is backlog.

| Source | Copy | Guard |
| ------ | ---- | ----- |
| `::keymap_default` | `docs/keyboard.md` chord table | `docs.tcl` |
| `::keymap_aqua` | `docs/keyboard.md`, *On a Mac* | `docs.tcl` 22 |
| `docs/*.md` on disk | `docs/index.md` | `docs.tcl` |
| provider settings door and window | `docs/agent.md` | `docs.tcl` |
| Profile row and its manager | `docs/agent.md` | `docs.tcl` 21 |
| openai extra-JSON rules | `docs/agent.md` | openai `api-face.test` |
| `_option_norm` keys | `wire::_option` allow-list | `agent-options.test` |
| what `prefs_save` writes | `docs/preferences.md` key table | `docs.tcl` |
| config and data path procs | `docs/preferences.md`, *Where everything lives* | `docs.tcl` |
| autosave interval | `docs/editor.md`, `docs/preferences.md` | `docs.tcl` 5a |
| menubar widgets | every menu the user documents name | `docs.tcl` 6, 7 (one way) |
| editor context menu | `docs/editor.md` | `docs.tcl` |
| Extensions menu's installer entry | its quoted path | `docs.tcl` 6a |
| `provider_has_settings` | Extensions window row button | `repos.tcl` |
| `rio::tls::bundles` | INSTALL.md §1 CA locations | `tls.test` |
| INSTALL.md §1 package names | `rio::deps::provides` | `deps.test` |
| `install-*` scripts | names the user documents quote | `docs.tcl` 20 |
| `LICENSE` | About's License row | `smoke.tcl` |
| About's rows | `docs/getting-started.md` table | `docs.tcl` 17 |
| D54's encoding guard | its copy in every runnable script | `encoding.test` |
| `rio-core/version.tcl` | CHANGELOG release heading | `changelog.test` |
| `adr/` records | CHANGELOG entries | `changelog.test` |
| `adr/` records | `adr/README.md` index | `adr/check.tcl` |
| the tree | README, *By the numbers* | none: a dated snapshot |
| shipped features | README, *What it does* | none: prose |
| `extensions/` | the publishing repository | none: a manual step |
