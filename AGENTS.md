# AGENTS.md — rio

> Working notes for agents, contributors, and maintainers. This is a **living
> decision log**: it records not just *what* we decided but *why*, so future
> work doesn't re-litigate settled questions or lose the reasoning behind them.
> Keep it current. When a decision changes, edit the decision and note the
> change — don't silently overwrite history.

> **Orientation for a new agent — read this first.**
>
> - **The load-bearing decisions**, if you read only a few: three layers —
>   core / frontends / optional server (D1); protocol-first transport (D2), now
>   collapsed to **one channel** (D30 — a pipe to a spawned local core, or a
>   socket to a remote one; **no in-process path**); the core owns the document,
>   frontends are **dumb views** (D3); and the **agent lives in the core**
>   (D26, over the channel since D30 P3).
> - **Tcl all the way down.** Core + GUI are Tcl/Tk; the (deferred) TUI is Ck.
>   **No Python — not even a scratch script.** Reach for `tclsh`, Edit/Write.
> - **Logic in the core; frontends stay dumb** (D1/D3). New behaviour almost
>   always belongs in `rio-core`, reached through an op — not in the GUI.
> - **Headless code stays Tk-free and `exit`s explicitly** (the D4 lesson: the
>   core, tests, the server, any verify probe). Loading Tk makes a bare `tclsh`
>   hang at EOF and map a stray window.
> - **Design every new op with a terminal client in mind** (O1) — structured
>   data, never Tk-shaped — so the protocol seam stays honest for the future TUI.
> - **Keep the docs in sync** (§7): a decision change → here, *with its why*; a
>   deployment change → INSTALL.md. This log is **append-and-annotate** — edit a
>   decision when it changes and note the change; don't erase the history.

Status: **early implementation.** A working UI-less core (`rio-core`) and a real
Tk editor (`rio-gui`) exist: open/save with encoding and line-ending
preservation, range-based editing, undo/redo, multiple buffers as tabs, a file
tree, a git read pane, a side-by-side compare view, live theming, and a working
**agent** (read + propose-edit + gated run-command with an opt-in trusted-command
allow-list, Claude over the official
Anthropic API). The GUI is **always a client to the core over a channel** — a pipe
to a private core it spawns locally, or a socket to a remote core; **there is no
in-process path** (D29/D30 retired it). Still mapped-but-unbuilt: the TUI and the
full plugin platform — see Sequencing. Decisions carry an *Implemented* note where
code now backs them.

> **Sequencing (read this).** This is a **multi-phase** project and there is **no
> application yet.** The full design space (agent, plugins, server) is mapped
> below, but we build in order: first a working **core + GUI** that edits real
> files, with the **Ck spike (O1)** to validate the TUI path.
>
> Mind the difference between **designing a seam** and **building a platform.**
> The plugin/protocol **boundary** (D2, D11, D16) is designed in from **day one**
> so nothing has to be bolted on later — but *building out* the full plugin
> **platform** (contribution API, manifests, permissions, SDKs — D17–D19) is
> **deferred**. The **agent subsystem (O4)** was deferred until a working core +
> GUI existed; that bar is now met, so its **core-orchestration slice is built
> (D26, slices 1–5; over the channel since D30 P3)** — the `agent.*` protocol, the
> provider interface, an in-box Claude provider over the official Anthropic API
> (API key), read + propose-edit, and gated run-command (D83) with an opt-in
> human-authored allow-list for trusted commands (D84). The agent's first providers ride the
> *thin* protocol-participant transport (essentially D11), **not** the full
> platform. The **marketplace** (O11) is deferred further still. Depth in this
> design log ≠ priority to build.

---

## 1. Vision

**rio** is a simple, language-agnostic IDE built for a plain-text-editor +
git + AI-agent workflow — nothing more. It is deliberately *not* a
language-feature powerhouse (no per-language IntelliSense ambitions). It is "an
advanced plain-text editor, with first-class git and AI-agent integration."

**North star — say it in one line:** *VSCode's quality, with 90s
productivity-software discipline, in a fraction of the code, written in Tcl/Tk.*

Let's be honest about the model: VSCode — Electron bloat and its vendor aside —
is genuinely **good** software. It's a high-quality, cross-platform IDE that
delivers a first-class experience on **both** Windows and Linux. That bar — the
*quality* and the *cross-platform parity* — is what we aim for. What we reject is
the weight: the giant codebase, the runtime, the feature sprawl. rio takes the
same ambition for craftsmanship, applies a much **smaller feature set** and a
**far smaller, human-readable codebase**, and carries the spirit of lean 90s
productivity software: fast, sharp, no wasted motion, something one person can
hold in their head. A lightweight VSCode in spirit — not a clone, a distillation.

We are **not** chasing reach or a thriving third-party ecosystem — there may
never be a community writing extensions, and that's fine. The reason rio is
extensible is *architectural*: a clean core that's cleanly supported by modern
software (LLM providers, tools, the odd plugin) ages better and stays small. We
build the extension seams because they keep the core honest, not because we
expect a crowd to fill them.

Inspiration: the spirit of small, personal, comprehensible editors — the kind
one person can hold in their head and actually use daily.

Guiding qualities:

- **Simple** — only what the workflow needs; resist feature creep.
- **Quality, the VSCode bar** — a genuinely first-class experience on Windows
  *and* Linux (and the BSDs), GUI *and* terminal. Cross-platform parity isn't an
  afterthought; it's the point.
- **Efficient & human-readable code** — the source should be a pleasure to read.
  90s-productivity discipline: do a lot with a little; every line earns its keep.
- **Cross-platform** — Linux (Debian, Alpine), the BSDs, **and Windows**.
- **Extensible by architecture, not by ambition** — a clean extension seam
  (D16–D19) keeps the core small and honest and lets modern software plug in
  cleanly. It's not a bet on a third-party crowd.
- **Two faces, one brain** — a GUI and a TUI, like `emacs` and `emacs-nox`,
  sharing all logic.

---

## 2. Scope

### In scope (the product)

- Editing files (the core: a capable plain-text editing surface).
- Git integration (status, diff view, stage/commit, branch awareness).
- A headless **command-execution primitive** in the core (run a command, capture
  output + exit code) — plumbing for git and the agent. **Not** a user-facing
  terminal pane or emulator (D15); manual testing happens in the user's own
  external terminal.
- AI agent–assisted coding: chat window, diff view of proposed changes,
  apply/reject. Orchestration + review UX in core; **providers ship as plugins**
  — Claude **and** local LLMs (D20).
- Tabs + side panes: file tree, git, agent/LLM chat.
- Responsive layout: side panes sit horizontally on wide screens; collapse into
  vertically stacked sections on narrow terminals.
- **GUI mode and TUI mode.**
- **Optional** server mode: the GUI/TUI is *always* a client to a core over a
  channel (D30), but the core can optionally run as a **persistent listening
  daemon** (socket, like `emacs-server` / `vscode-server`) rather than a private
  core spawned over a pipe. (Pre-D30 this read "in-process is the default" — there
  is no in-process path anymore.)
- A **language-agnostic plugin/extension *seam* designed in from day one** (D16):
  the protocol boundary is provided for up front so extensibility isn't bolted on
  later. *Building out* the full plugin platform (contribution API, manifests,
  permissions, SDKs — D17–D19) is **deferred** until core+GUI exist (see
  Sequencing); the *marketplace* (O11) is deferred further still.

### Explicitly out of scope (at least for v1)

- Per-language IDE features (LSP, language-aware refactors, semantic completion).
- **Any terminal pane or terminal emulator** — no PTY, no interactive shell, not
  even an opt-in one (D15). Use your own terminal.
- TUI **mouse** support — keyboard-driven only (see Decisions).
- Extension **marketplace** / in-app install (deferred — O11). The plugin *seam*
  is designed in now (D16) and manifest + permissions are specced (D19) so the
  marketplace isn't bolted on later — but *building* the plugin platform is itself
  deferred until after core+GUI (see Sequencing).
- Remote/multi-user collaborative editing (the model permits it later, but it's
  not a goal).

---

## 3. Architecture & Key Decisions

Each decision records the reasoning. Numbered for reference.

### D1 — Three layers: core / frontends / optional server

```
                 ┌────────────────────────────────────────┐
                 │   rio-core  (pure Tcl, no UI)            │
                 │   document model · undo · file I/O       │
                 │   git · LLM/agent orchestration          │
                 │   project/session state · command bus    │
                 └───────────────┬────────────────┬─────────┘
                                 │                │
                  in-process call│        socket  │ (server mode)
                                 │                │
                 ┌───────────────┴──┐   ┌─────────┴───────────┐
                 │ rio-gui (Tk)     │   │ rio-tui (Ck/curses) │
                 │ thin view layer  │   │ thin view layer     │
                 └──────────────────┘   └─────────────────────┘
```

*(Transport labels above are the original D1/D2 framing. **D30 superseded them:**
a frontend is now always a client over a **channel** — a pipe to a spawned local
core, or a socket to a remote one — with no in-process call. The three-layer
split itself is unchanged.)*

- **`rio-core`**: pure Tcl, zero UI dependency. ~80% of the code and *all*
  business logic. Document model, undo, file I/O, git (shell out to `git`,
  parse porcelain), LLM/agent orchestration, project/session state, command
  dispatch.
- **Frontends** (`rio-gui`, `rio-tui`): thin. They render core state and turn
  input into core commands. No business logic.

**Why:** one separation solves three requirements at once — (a) GUI+TUI without
duplicated logic, (b) optional server mode, (c) "simple, readable" by keeping UI
toolkits out of the logic.

**Implemented (GUI):** `rio-gui/rio-gui.tcl` is a minimal but real Tk editor on
the core — open/save (fs.*), range-edit (buffer.*), undo/redo (edit.*), and
multiple buffers as tabs (buffer.new / buffer.close), themed from the core's role
table (theme.get / D24, with a live-switching View menu), with a menu, tab bar,
and status line. It is **always a client to the core over a channel** — a pipe
to a spawned local core by default, a socket to a remote one (`--connect`); the
in-process embedding this originally used (`rio::core::call`, synchronous) was
retired by D29/D30, so `rio_call`→`core_call` over `::core_chan` is the one path.
It stays a *dumb view* (D3): keystrokes become `buffer.replace` requests via a
widget-command proxy, and the screen only changes when the core echoes
`buffer.changed` back.
The core owns the buffers; the frontend keeps only the per-buffer *view* state —
tab order, the active tab, and each buffer's cursor/viewport (frontend-local per
D22). A headless smoke (`rio-gui/tests/smoke.tcl`) drives it without showing a
window. `rio-tui` does not exist yet (O1).

### D2 — The core API is a *message protocol*, transport-independent (protocol-first)

The core exposes a request/response + event-stream API designed as a protocol
from day one, **independent of transport**:

- **In-process** (default, no server): transport is a direct in-memory call.
- **Server mode**: the *same* commands marshaled over a Unix socket / TCP.

> **Superseded by D30 (kept for the reasoning).** The in-process transport is
> gone — the frontend is *always* a client to a core over a **channel** (a pipe
> to a spawned local core, or a socket to a remote one). The protocol-first
> design here is exactly what let server mode and then the channel collapse to
> one path cheaply; the reasoning stands, only "in-process is the default" changed.

**Why:** server mode stops being a second codebase — it's the same core with a
different transport. `emacs-server` semantics fall out for free, and "server is
optional" becomes automatic. We will *ship* in-process first but design the API
this way from the start to avoid a later rewrite.

A further benefit — **the TUI risk insurance.** Because frontends *only* speak
this protocol, a frontend can be written in *any* language. If the Ck TUI (O1)
disappoints, the TUI can be reimplemented (Perl/`Curses::UI`, a Go/Rust TUI,
etc.) against the same core without touching it. So O1 is a gate on **Ck
specifically**, not on the project.

### D3 — The core owns the canonical document; frontends are views

The buffer/document model of record lives in **core**. Frontends are *views*
onto it. Editing in a widget emits edit-commands → core applies → core
broadcasts → all views update.

In particular, the Tk `text` widget is a **display surface, not the source of
truth**. (We still use its tags for highlighting/diff coloring — just not as the
store.)

**Why:** server mode *requires* this (the buffer lives on the server; clients
are windows onto it). It also gives a single source of truth and is the only
model where GUI + TUI + server coexist without duplicating buffer logic.

### D4 — Stack: Tcl/Tk for core + GUI; **Ck** (curses) for the TUI

- Core + GUI: **Tcl/Tk**. Chosen for genuine cross-platform reach, single-file
  distribution (Tclkit/starpack, and the `vanillawish` build), and because the
  Tk `text` widget is a strong editing surface (built-in undo, tags, marks). And
  because the maintainer wants to build something real in Tcl/Tk.
- TUI: **Ck** — a Tk-shaped toolkit that renders to curses (Tk-parallel
  widgets: `text`, `listbox`, `entry`, `frame`, `menu`, `scrollbar`; `pack`/
  `grid` geometry). This is the "emacs-nox" analogue at the toolkit level and
  lets the TUI frontend share Tk idioms with the GUI, not just the core.
  - Candidate builds: [`vzvca/ck8.6`](https://github.com/vzvca/ck8.6) (Tcl 8.6)
    and Christian Werner's `vanillatclsh` (single-file, Linux/macOS/Windows).
  - `vanillawish` (GUI) and `vanillatclsh` (TUI) are same-lineage single-file
    executables — they double as our distribution vehicles.

**Why not build a TUI from scratch:** Ck gives Tk-parallel widgets, raising the
code-sharing ceiling and removing the riskiest custom work.

**Fallback (not chosen):** Perl/Tk + `Curses::UI` — Perl has a more mature TUI
library but the same dated Tk and weaker single-binary story. Only revisit if
the Ck spike (O1) fails.

**Dev toolchain (concrete).** A contributor needs `tcl`, `tk`, `tcl-tls`
(Claude HTTPS, D8), `tcllib` (`json` for the protocol), and `git` (D7).
[`rio-dev-deploy.sh`](rio-dev-deploy.sh) installs these across apt / apk /
`pkg_add`, and behind `--with-ck` builds Ck from source for the TUI path; it
finishes by loading Tk, `tls`, and `json` through `tclsh` as a smoke test.
*Lesson worth keeping (reinforces D1):* anything headless — that verify probe,
the UI-less core, tests, a server — must stay Tk-free and `exit` explicitly.
Once Tk is loaded, `tclsh` drops into the event loop at stdin EOF (hangs) and
maps an empty window unless withdrawn. Only the GUI frontend touches Tk.

### D5 — TUI is keyboard-driven only; no mouse

**Why:** TUI mouse is terminal-dependent and perpetually slightly-off; dropping
it removes the most platform-fragile part of Ck from our dependency surface. A
simplification that also de-risks. Keyboard-first suits the target workflow.

### D6 — Windows TUI path: Cygwin (primary), native PDCurses (fallback)

Running `rio tui` under **Cygwin** uses *real ncurses* — the same code path as
Linux/BSD — avoiding the less-proven native-Windows PDCurses path. Native
PDCurses (via `vanillatclsh-win32`) remains a fallback; note it is BMP-only
Unicode (fine for a code editor; no emoji). The GUI runs natively on Windows
regardless.

| Platform        | GUI (Tk)      | TUI (Ck)                         |
|-----------------|---------------|----------------------------------|
| Linux / BSD     | native Tk     | native ncurses ✓                 |
| Windows native  | native Tk     | PDCurses (works, BMP-only)       |
| Windows + Cygwin| —             | real ncurses, same as Linux ✓    |

### D7 — Git via shelling out to `git`

Parse `git` porcelain output; no libgit2 dependency.

**Why:** portable, dependency-light, simple. Matches the "simple, efficient"
ethos and works identically everywhere `git` is installed.

### D8 — LLM access behind a stable provider interface (providers are plugins)

Core defines a **stable provider interface** — the durable contract: given a
conversation + available tools, stream assistant output and tool-call requests.
**Concrete providers are plugins** (D16), not built-in modules: first-party
**Claude** (HTTPS — needs `tcltls`) and **local-LLM** (OpenAI-compatible /
Ollama / llama-server) providers ship in-box and dogfood the interface; others
are community plugins.

**Why:** specific services are *volatile* — APIs change, get renamed, SaaS come
and go. Isolating each behind a plugin means provider churn never touches core:
core standardizes the *interface*, plugins absorb the *wire specifics*
(HTTP/REST/JSON/SSE/…). See D20 for the full core-vs-plugin split of the agent.

**Phasing note:** a provider is a protocol participant over the **thin** D11 seam
— it does **not** require the full (deferred) plugin platform (D17–D19). So the
in-box Claude / local-LLM providers can land *with* the agent subsystem without
waiting on the contribution API, manifests, or SDKs. This is what keeps the agent
buildable after core+GUI without first finishing the whole plugin platform.

### D9 — Responsive layout rule is a shared pure function

The collapse rule — `(width, panes) → layout` (horizontal vs vertically
stacked) — lives in core as a pure function both frontends render.

**Why:** the *policy* is shared (no duplication); only the *rendering* differs
per frontend (Tk geometry managers vs Ck geometry managers).

### D10 — Async via Tcl's event loop / coroutines

Long operations (LLM streaming, git, file watching) must never block the UI;
use `fileevent` + coroutines (Tcl 8.6+) for readable async.

**Why:** Tcl is single-threaded by default; coroutines keep streaming code
linear and readable while staying responsive.

### D11 — Wire protocol: newline-delimited JSON (JSONL), request/response + events

Three message kinds:

- **Request** (client → core): `{id, op, params}`
- **Response** (core → client): `{id, ok: true, result}` or
  `{id, ok: false, error}`, where `error` is a flat object `{code, message}` — a
  stable machine-readable code plus a human message (the taxonomy, O2).
- **Event** (core → client, unsolicited): `{event, params}` — broadcast to all
  attached views.

Encoding is **JSON, one message per line** (JSONL framing) over the channel;
inside the core the same dict structure is passed directly, so op-to-op calls
(dispatch, the agent calling a tool) pay no serialization cost — JSON lives only
at the channel boundary. *(Post-D30 the frontend↔core hop is **always** a channel
and always serializes; the zero-cost dict path survives only as the core's
**internal** dispatch, not a frontend transport. D25's "in-process path" mentions
mean this internal path.)*
A streaming op (`agent.send`) emits a sequence of events keyed by a run id (the
agent uses a per-conversation `turn`), terminated by a final event. Op
namespaces: `buffer.*`, `fs.*` / `project.*`, `git.*`, `exec.*`, `agent.*`,
`session.*`. (The command-execution primitive is `exec.run` — synchronous, not
streaming; see O2/D15.)

**Why:** JSON is language-neutral (supports the D2 any-language-frontend safety
net), human-readable (debuggable by eye), and trivially mirrors a Tcl dict.
JSONL framing is dead simple and stream-friendly.

### D12 — Document model: list of lines, `line.col` coordinates

A buffer is an **ordered list of line strings**. Positions and ranges use
`line.col` (1-based line, 0-based column) — **the same index format as the Tk
`text` widget** — so the GUI view layer maps near-free. Edits are **range
replacements**: replace `[start, end)` with text; insert/delete are degenerate
cases. Change events carry the replaced range + new text so other views resync.

**Why:** for source-file sizes this is simple, readable, and fast enough; a gap
buffer / rope is premature optimization. Sharing Tk's `line.col` convention
keeps the GUI view thin (D3).

### D13 — Layout regions + the "collapsible section stack" primitive

A VSCode-shaped layout with a fixed set of logical regions:

- **`nav`** (left) — Files + Git, as stacked collapsible sections.
- **`editor`** (center) — tabbed; splittable into **two editor groups** for
  side-by-side / diff viewing.
- **`chat`** (right) — the agent/LLM conversation + input + inline proposed-edit
  diffs (apply/reject). Command output that the agent needs to show (e.g. a
  failed test run) surfaces *here*, in the conversation flow — there is no
  separate terminal pane (D15).
- **`status`** (bottom, 1 line) — always present; the only permanent bottom
  element, a thin tmux/`screen`-style bar (D15).

One UI primitive is reused everywhere: a **collapsible section stack**. It backs
both the left nav (Files/Git) *and* the narrow-mode collapse of all side panes
(D14). Build it once, well.

Layout is **user-adjustable but not free-form** in v1: pane visibility and sizes
can be toggled and are remembered per session; full drag-rearrangement is
optional/later ("nice but not a must"). Chat defaults to the right (toggleable).
Focus moves between regions by keyboard (keymap TBD, O6).

**Why:** mirrors a familiar mental model; collapsing the whole layout to one
reusable primitive keeps both frontends simple and visually consistent.

### D14 — Responsive tiers (the D9 policy) + diff fallback

The `(width, panes) → layout` function (D9) resolves to three tiers:

- **Wide** — `nav | editor | chat` as columns; one-line `status` at the bottom.
  No bottom pane (no terminal/runner region — D15).
- **Mid** — keep one side column (the focused one); the other collapses to a
  toggle.
- **Narrow** — single column; `nav` and `chat` become **vertically stacked
  collapsible sections** around `editor`; only expanded ones take height.

Editor split: two groups side-by-side when wide enough; **a side-by-side diff
falls back to a unified diff when too narrow.** Breakpoints are tunable (initial
guess: wide ≥ ~100 cols-equiv, narrow < ~70); the GUI maps window width to the
same tiers.

**Why:** turns D9 into concrete policy; the diff fallback keeps diffs usable on
small terminals (D5 keyboard-only world).

### D15 — No terminal pane; the bottom is a thin status bar only

rio ships **no terminal/runner pane at all** — not even an opt-in one. The only
thing at the bottom is the one-line **`status`** bar: a dense, informational
tmux/`screen`-style strip, no wasted rows. Manual testing and debugging happen
in the user's **own external terminal** (xterm, xfce4-terminal, …); that is the
documented, endorsed workflow.

This does **not** remove command *execution* — it removes the terminal *UI*.
A headless **command-execution primitive** stays in the core (run a command,
capture stdout/stderr + exit code), because git (D7) and the agent (D20) both
depend on it. When command output needs to be *seen*, it surfaces in the
relevant flow (e.g. the agent's `chat` conversation reacting to a failed test),
not in a dedicated terminal widget.

**Why:** an interactive terminal emulator is the single nastiest cross-platform
component — PTY handling, ANSI/cursor emulation, resize — and worst of all a
terminal-inside-a-terminal under Ck. It's also the part the user least needs:
real debugging happens in a real terminal. Cutting the *pane* (while keeping the
headless run-command primitive the agent/git already require) removes a whole UI
region, a major complexity sink, and an open question — losing nothing essential.
Simple-by-default taken to its logical end: don't build the surface at all.

### D16 — Extensibility: a plugin is a protocol participant (any language)

A plugin attaches to the **same D11 protocol** as a frontend — it is just
another participant. Two tiers, identical contribution API, differing only in
transport (mirrors D2):

- **Out-of-process, any language (primary).** Core spawns the plugin as a
  subprocess speaking JSONL over stdio/socket. **Language-agnostic by
  construction** and **isolated** — a crashing plugin cannot take down core
  (serves the rock-solid goal).
- **In-process Tcl (opt-in).** Loaded as a Tcl package; direct calls instead of
  IPC, for trusted or performance-critical extensions.

Consequence: rio does **not** "support Lua/Perl/Python" individually — it
supports one protocol; any language that can read/write JSON works. Thin
per-language **SDKs** live *outside* the core; the community can add a language
without core changes. Core ships the Tcl SDK + one reference SDK.

**Why:** reuses the language-neutral boundary we already have, so multi-language
is nearly free; isolation improves robustness; the core stays small.

### D17 — Contribution points (the extension API surface)

What a plugin may register: **commands** (palette + bindable), **keybindings**,
**event subscriptions** (buffer / save / git / …), **providers** (formatter,
linter/diagnostics, syntax highlighter, LLM provider, VCS backend), and **UI
contributions** (D18). Buffer/text manipulation reuses existing `buffer.*` ops.

Stance: the core stays minimal; capabilities beyond the basics are plugins —
even syntax highlighting or an LSP bridge can be plugins rather than core. rio
ships some **first-party plugins built on the same API** to dogfood and keep it
honest.

**Why:** a small, comprehensible core where the plugin API *is* the
extensibility story, not an afterthought.

### D18 — UI contributions are declarative, rendered by both frontends

Plugins contribute **structured/semantic UI** ("add a nav section showing this
tree", "add a status item", "decorate these ranges", "add a panel with this
list/text") — **never raw Tk or Ck widget code.** Both frontends render the
same declarative contribution.

**Why:** a plugin must not need to know Tk vs Ck; declarative contributions
preserve GUI/TUI parity and keep plugins portable. This is the trickiest part of
any cross-frontend plugin system, addressed by construction.

### D19 — Plugin manifest + permissions; marketplace deferred

Each plugin ships a **manifest**: identity, entry/run-command + language,
declared contributions, and **declared permissions** (filesystem scope, network,
run-command). The user consents to permissions on install. Out-of-process
isolation makes real sandboxing *possible* later. A **marketplace / in-app
install** (VSCode-style) is **not off the table but deferred** — designing
manifest + permissions now means it isn't bolted on later (note: a marketplace
raises trust / supply-chain / signing concerns to handle then).

**Distribution leaning — git is the store.** When/if rio gets a "store," the
direction is *not* a bespoke marketplace service. **git is already a solid
distribution medium** for extensions, so a plugin is just a git repo (clone /
pull to install and update). The default catalog can be a plain **Forgejo
instance** that a single maintainer (e.g. rio's author) hosts — people upload
their extensions there, others pull from it — e.g. a configurable default like
`forge.example.org/rio/apps`. Crucially the underlying tech is **agnostic**: the
default store is just one entry in config, and pointing rio at *another* Forgejo
(or any git host) must be trivial. This keeps "distribution" a one-person,
self-hostable, no-special-infrastructure affair — fitting the not-chasing-reach
stance — rather than a platform we have to run.

**Why:** extensibility *designed in* from day one without the trust/distribution
burden up front; security-minded defaults (explicit capability declaration +
consent); and
when distribution is needed, lean on git/Forgejo rather than building (and
operating) a marketplace platform.

*(Since realized — D39, with one revision: distribution landed as plain-HTTP
directory repositories, apt-sources style, and **git was dropped as the
transport** — the durability bar ("works even if git disappears") and v1
simplicity favoured bare webdirs, which a Forgejo raw-URL prefix still
satisfies. The spirit of this decision — self-hostable, no platform to
operate, the store is one config entry — is exactly what D39 shipped for
syntax/modes/themes; manifest + permissions for *plugin*-kind extensions
remain ahead, and D39's manifest format is built to grow those keys.)*

### D20 — Agent architecture: orchestration in core, providers & tools as plugins

The agent splits along a **security / volatility** line:

- **Core (durable, security-critical):** the agent *orchestration loop* (the
  conversation state machine, tool dispatch), the **diff/apply review UX** and
  chat pane (first-party), and the **guardrails** around tool execution (file
  writes, run-command — O4). The user reviews proposed changes the *same* way
  regardless of provider, and every tool call is mediated by one permission
  model.
- **Plugins (volatile / extensible):** concrete **providers** (D8) and
  **additional agent tools** beyond the built-ins (read/write/run/search), each
  registered via D17 contribution points.

The two durable interfaces to standardize — the **provider interface** and the
**agent-tool/context interface** — are strong candidates to align with **MCP**
(Model Context Protocol; JSON-RPC for exposing tools/resources to LLM apps)
rather than inventing a bespoke contract that ages badly. rio as an **MCP
client** would consume MCP servers as tools/providers for free (O12).

**Why:** answers "should the agent be an extension?" precisely — *providers and
extra tools* are plugins (isolating volatility exactly as desired), but the
*tool-executing orchestration and review UX* stay core, because that is where
security and cross-provider consistency live. Aligning the interfaces with MCP
keeps them modern and non-proprietary. (Note: VSCode puts orchestration in
extensions; we deliberately don't, for the security boundary — revisitable.)

### D21 — Config & session: plain text, XDG locations, no executable config

Two kinds of state, kept separate:

- **User settings** (human-authored): a flat, human-readable **key-value** file
  (INI/`key = value` style, UTF-8). Editable by hand in any editor, diff-friendly,
  no surprises. It is **data, not code** — rio does *not* `source` a Tcl script as
  config (no arbitrary code execution on startup).
- **Session/workspace state** (machine-written): recent files, window/pane sizes,
  open tabs, per-view cursor positions — written as **JSON** by rio, not meant for
  hand-editing. *(Realized by **D31**, which splits this by owner — view prefs under
  config, the per-project open-file set under data — and stores the session **out of
  tree** keyed by project root, superseding the "project-local session in `.rio/`"
  sketch below for resume state.)*
- **Secrets** (tokens/credentials, e.g. the Claude API key of D26): kept
  **out of both** the plain-text settings file and the synced session JSON, in a
  separate store under the data dir with **restrictive perms (0600)** — OS keychain
  later. They are machine-written, never hand-edited, and must not ride along in a
  diff-friendly config a user might commit or sync. *Implemented* in
  `rio-core/secret.tcl` (one `<name>.secret` file per token set, the rio::conf
  key=value format, the dir 0700 / files 0600).

**Locations** follow the **XDG Base Directory** spec on Unix:
`$XDG_CONFIG_HOME/rio/` (config; default `~/.config/rio/`) and
`$XDG_DATA_HOME/rio/` (session/state; default `~/.local/share/rio/`), with the
documented fallbacks. Windows uses the native equivalents (`%APPDATA%` /
`%LOCALAPPDATA%`). **Per-project** overrides live in a `.rio/` directory at the
project root (settings + project-local session), so a repo can carry its own
config without polluting global state.

**Why:** matches rio's "simple, rock-solid, human-readable" spirit and a Unix
purist's expectations; plain key-value is trivial to read, write, and diff;
refusing to execute config removes a whole class of startup-fragility and
security footguns; JSON for machine state reuses what we already parse for the
protocol (D11); XDG + per-project `.rio/` is the least-surprising layout.

*(Amended 2026-09-02 — what Windows actually does.)* The sentence above says
"Windows uses the native equivalents (`%APPDATA%` / `%LOCALAPPDATA%`)". That was a
design intent and **is not implemented**: `secret.tcl`, `workspace.tcl`, `theme.tcl`
and `agent-prompt.tcl` all use the one XDG-with-`HOME`-fallback ladder on every
platform. Verified on Windows 11 during the first native run (RELEASING.md Gate 0),
this turns out to be **fine rather than broken**: Tcl synthesises `env(HOME)` from
`HOMEDRIVE` + `HOMEPATH`, so with no XDG variables set rio lands in
`%USERPROFILE%\.config\rio` and `%USERPROFILE%\.local\share\rio` and persists
correctly. So the ladder is genuinely cross-platform and one code path serves all
hosts — the argument for adding `%APPDATA%` is now only native-Windows convention,
not function. Left unbuilt on purpose; noted in ROADMAP. The one real casualty is
the `0600`/`0700` lock-down in `secret.tcl`, which is a `catch`-wrapped no-op on
NTFS — the API key file inherits user-profile permissions instead (WINDOWS.md §7).

### D22 — Encoding, line endings, and cursor locality

Resolves the easy half of the document model (D12):

- **Encoding:** **UTF-8 by default**, with detection of an existing file's
  encoding on open and **preservation on save** (don't silently rewrite). A BOM,
  if present, is preserved.
- **Line endings:** **detect and preserve** the file's existing convention
  (LF vs CRLF) per file; new files default to **LF**. Never normalize silently;
  mixed-ending files keep their dominant style with the choice surfaced, not
  forced.
- **Cursor/selection are frontend-local.** The core owns the canonical document
  (D3); each frontend keeps its *own* cursor/selection/viewport. The protocol
  carries edits as range operations (D12), not "where the cursor is." (Promotes
  the O3/O1 "leaning yes" to settled.)

**Why:** encoding/line-ending preservation is table-stakes for an editor people
trust with real repos (especially cross-platform, where CRLF churn is a classic
diff-noise bug); keeping cursor state frontend-local keeps the protocol small and
lets GUI and TUI (or two views of one buffer) move independently without round-
trips. Undo/redo structure and large-file/lazy-load remain open (O3).

**Implemented** in `rio-core/fs.tcl` (detection/preservation) and the `fs.*` ops
(`file.open`, `file.save`) in `rio-core/ops-fs.tcl`; the detected encoding/BOM/EOL
ride along as opaque per-buffer metadata in the document model so a save
reproduces the original on-disk form. Detection is honestly bounded: UTF-8
(BOM-or-not, validated per RFC 3629) with a lossless iso8859-1 byte-fallback;
LF/CRLF. UTF-16, bare-CR, and lazy-loading large files are explicitly out of
scope for now (the latter is still O3).

### D23 — Keybindings are data, not hardcoded

The **binding model** is decided even though the exact default keys aren't: rio
maps keys through a **lookup table from key-chord → named command**, loaded as
data and overridable via user config (D21). Frontends never hardcode behaviour to
a key. GUI and TUI share **one logical command set**; the TUI's *achievable*
chords are bounded by what terminals actually deliver (Ctrl/Alt/function-key
coverage), which O1 validates. A default scheme ships; users can remap.

**Why:** data-driven bindings give GUI/TUI parity for free, make remapping a
config edit rather than a code change, and keep keymap churn out of the
frontends. The concrete **default keymap** (and any modal-vs-modeless stance)
stays open — that's the narrowed O6. *(Since answered: D38 — editing modes;
the app-chord table here always wins over the active mode's keys.)*

*(Implemented — GUI keymap as one table.)* The GUI's shortcuts were briefly hardcoded
twice over (the `bind`s in `editor_bindings` and again as literal `-accelerator` strings
in the menus — two places to drift). They now come from a single `::keymap_default`
table: `command → {chord action}`. `editor_bindings` binds each command's chord on every
group's text widget (still with `; break`, so Tk's own class bindings don't double-fire),
and every menu `-accelerator` is derived from the same table via `chord_label` (so a
remap moves the key *and* its menu label together). A menu item may still run a different
`-command` than its key (split-editor's key toggles, its menu only splits) — the menu
just borrows the chord for display. Users remap in **`$XDG_CONFIG_HOME/rio/keys.json`**
(D21 config home; a sibling of `prefs.json`, `themes/`, `syntax/`): `{"command":"chord"}`
overrides one default chord, `""` unbinds. Adding a command is a one-line table entry —
no second edit. **Robustness follows the prefs rule** (a broken config never stops the
editor): a missing/corrupt file, an unknown command, or a mis-modified chord is skipped
and collected in `::keymap_bad`, surfaced *once* as a post-startup notice so a botched
remap isn't silently ignored. Chord validity only checks the *modifiers* — Tk's `bind`
accepts almost any string (unknown tokens become keysyms that never fire), so a probe-bind
can't flag a typo; validating the modifier tokens catches the likely mistake without
enumerating every keysym. Covered by `rio-gui/tests/keymap.tcl` (defaults, label
derivation, override/unbind, garbage rejection, and that the resolved map actually drives
the per-widget bindings). The keymap is the frontend's view concern — no core, no wire.
This narrows O6: the GUI default scheme is now concrete; the TUI's and any modal stance
stay open *(the modal stance has since landed too — D38's editing modes, vi included)*.
Live remap without restart, and a keybindings UI, are the obvious next steps
(today: edit `keys.json`, relaunch).

*(Follow-on — live remap + a shortcuts editor.)* The "edit and relaunch" caveat is gone.
Each `::keymap_default` entry now carries a third field, a human `label`, so the map can
name itself in a UI (an override still changes only the chord; `keymap_resolve` `lreplace`s
index 0 and keeps action+label). Two mechanisms turn a keymap change into a running-UI
change with no restart: `keymap_rebind_all` clears the chords bound last time
(`::keymap_live_chords` — `bind` overwrites but never removes, so a changed/unbound chord
must be explicitly cleared) and re-binds the current set on every group; `keymap_refresh_menus`
re-derives every accelerator. `keymap_apply_live` = re-read the file, then both — the one
entry point after any runtime change, so file and UI never diverge. On top sits **Settings ▸
Keyboard Shortcuts…**, a modal that edits a working copy (`::keys_work`, command→chord),
records chords **press-to-capture** like a modern IDE (`event_to_chord` maps `%K`/`%s` →
a chord, refusing a bare modifier or a lone printable that would hijack typing, live
conflict-checked via `keys_conflict`), and on Save writes only the diff from the defaults
(`keymap_overrides` → `keys_save`, deleting `keys.json` when nothing differs) then applies
live. The pure pieces (`event_to_chord`, `keys_conflict`, `keymap_overrides`, live rebind,
and the dialog driven end-to-end) are covered in `keymap.tcl`; the capture *binding* is a
one-line `<KeyPress>` guard, verified by hand with a real `event generate` (headless it's
a transient of the withdrawn root, so unmapped — the test drives the handlers directly).
Still a pure frontend concern — no core, no wire.

### D24 — GUI theming: semantic roles in plain data files (themes are data, not code)

The **GUI is themeable**, and a theme is a flat, human-readable data file — the
same `key = value` / `[section]` style as config (D21), `#` comments, UTF-8.
**Theme files are data, never executed** — rio does *not* `source` a theme as
Tcl (same footgun-removal as D21). A theme names **semantic roles**, not widget
paths, mapped onto the D13 regions:

- **Colors by role:** `editor.bg`, `editor.fg`, `editor.selection`, `chat.bg`,
  `chat.fg`, `ui.bg`, `ui.fg`, `gutter.fg`, `accent`, … solarized-light vs
  solarized-dark then differ *only* in the values; the GUI wiring is identical.
- **Fonts by role, via named fonts:** a small set (`RioEditorFont`,
  `RioChatFont`, `RioUIFont`) that widgets reference *by name*, so the coding
  surface and the agent chat can carry **different family/size**. Reconfiguring
  a named font updates every widget using it **live**, so font-size and theme
  switches need no restart.

A thin **theme applier** in the GUI frontend reads the role table and pokes Tk:
`font configure` for the named fonts, the **option database** for classic-widget
defaults (the `text` editor, labels), and `ttk::style configure` for any themed
widgets — plus explicit per-region re-config so switching is live (the option DB
only affects widgets created after it's set). Keeping that Tk-specific mapping in
code is what lets theme files stay dumb, portable, and safe.

The shipped **default is the plain white-bg/black-text look** (the "90s
productivity" aesthetic); themes are opt-in. `solarized-light`, `solarized-dark`,
and `acme` (Plan 9's pale-yellow body / pale-blue tag bars) ship as example files
under `$XDG_CONFIG_HOME/rio/themes/`. A theme may optionally declare
`base = <theme>` and override a few roles rather than copy the whole set.

**Scope:** theming is a **GUI concern** (D1) — fonts have no meaning in a
terminal. But the **color-role vocabulary is shared**, so a future TUI theme can
map the same roles onto the terminal's 16/256-color palette without inventing a
second model.

**Why:** roles-not-paths make a new theme a pure value set; named fonts give
per-section typography and instant, restart-free changes; refusing to execute
theme files reuses D21's security/robustness stance; a built-in default keeps the
look people love without a theme file present.

*(Later: the chat's **error** text and the **diff/compare bands** joined the role
vocabulary — `error`, `diff.added`, `diff.removed`, plus the compare pane's
`diff.added.bg` / `diff.removed.bg`. They had been hardcoded pastels in the
applier, which glared on a dark surface — exactly the D24 anti-pattern. Now they
default to the old light values (so light themes are unchanged) and
`solarized-dark` retints them from its own palette; a theme that omits them
inherits the defaults, same as the `syntax.*` roles under D32.)*

**Implemented (core, data side).** The role table is served as data so the GUI
applier (and a future TUI) carry no theme-loading logic. `rio::conf` parses the
shared `[section]`/`key = value` format (D21) — parsed, never executed.
`rio::theme` owns the built-in default + the concrete role vocabulary and merges
a named theme file over its `base`. `theme.get {?name?}` returns the role table
`{colors {…} fonts {…}}` — the protocol's third non-flat result, a *nested
object*, encoded via `rio::wire::objmap` (the result-encoder registry again).
`themes/solarized-dark.theme` and `…-light.theme` ship as examples; tests load
them. The **concrete role vocabulary is now fixed**: colours
`editor.bg/fg/cursor/selection`, `ui.bg/fg`, `tab.bar.bg`/`tab.active.bg`/
`tab.inactive.bg`/`tab.fg`, `gutter.fg`, `chat.bg/fg`, `accent`; named fonts
`RioEditorFont`, `RioUIFont`, `RioChatFont` (each `family`/`size`).

**Implemented (GUI applier).** `rio-gui` fetches `theme.get` at startup and maps
the role table onto Tk (`apply_theme`): `font create`/`font configure` for the
named fonts (so a size change is live), explicit per-widget colour config on the
editor / status bar / tab bar (so a switch is live), and `option add` font
defaults for widgets created later. A **View menu** switches Default / Solarized
Dark / Solarized Light / Plan 9 Acme live, with no restart. The default theme
reproduces the plain white-bg look. **Open:** colour-theming dialogs / the future chat pane via
the option DB, and how much rio leans on `ttk` vs classic widgets — both firm up
as the shell grows.

### D25 — JSON value encoding is shape-aware, not value-sniffed

The canonical internal form is plain Tcl dicts (D11: the in-process path uses
them with no serialization), so JSON lives **only at the socket boundary**. A
*generic* dict→JSON encoder is impossible there — Tcl can't tell the string
`"hi there"` from the two-element list `{hi there}` — so the boundary encoder is
**shape-aware**, never guessing types from values:

- The **envelope shape is fixed**: `id` is a wire **string** (ids are opaque
  tokens on the wire), `ok` is a bare `true`/`false`, and a reply carries either
  `result` (object) or `error` (a flat `{code, message}` object, O2).
- `result` and event `params` are **flat objects whose leaf values encode as
  JSON strings** — exact for every value the protocol carries today (text,
  `line.col` indices, ids, removed text). Inbound parsing uses tcllib's
  `json::json2dict`, which is unambiguous.
- When an op needs a non-string leaf (a number, nested object, or array),
  **that op declares its shape**; we never sniff Tcl values for type. *How* an op
  declares it is now settled (first used by `buffer.list`): the op returns a
  plain Tcl dict as always, `dispatch` carries the `op` name on the reply, and
  `rio::wire` keys a **result-encoder registry** by op — so the encoder is told
  the shape. Unregistered ops use the flat-object encoder; `rio::wire::arr` builds
  arrays from already-encoded fragments. The in-process path is untouched.

**Why:** value-sniffing is the classic Tcl→JSON footgun (a string that happens
to look like a list or a number gets mis-typed); pinning the envelope and
treating leaves as strings is total, debuggable, and correct for the current
protocol, while leaving a clean path (per-op shape declarations) for richer
payloads. Keeping JSON at the boundary preserves D11's zero-cost in-process path.
Implemented in `rio-core/wire.tcl`; the socket transport (`server.tcl`) is the
same dispatch as in-process (D2), proven by a real-socket round-trip test.
*(Later hardened: `rio::wire::str` now `\u`-escapes every C0 control character —
RFC 8259 requires all of 0x00-0x1F escaped. tcllib's parser tolerated them raw, so
Tcl↔Tcl never noticed, but a strict JSON parser rejects the whole line, and D2's
any-language-frontend promise rides on the wire being real JSON.)*

### D26 — Agent subsystem, first slice: `agent.*` protocol + provider interface; in-box Claude over the official Anthropic API

Activates the **core-orchestration slice** of the agent (D20 / O4) now that a
working core + GUI exists. Scope was deliberately narrow; the run-command surface
followed later, gated, as **D83**.

**Protocol (`agent.*`, core-owned).** One streaming op drives a turn:
`agent.send {text}` starts/continues the orchestration loop for the open
conversation, streaming events keyed to the request id (D11/D14 streaming):
`agent.delta` (assistant token chunks), `agent.tool` (a *proposed* tool call
awaiting the user's permission), `agent.message` (a completed turn), and
`agent.error` (a *classified* failure — see resilience). Conversation state lives
in core; the GUI chat pane is a dumb view (D3) over this stream. Events are
designed **terminal-aware** by construction — structured conversation data (roles,
text spans, proposed-edit diffs as D12 ranges), never Tk-shaped payloads — so a
future TUI renders the same stream. This is the O1 commitment to design the first
*rendering-heavy* namespace with a cell-grid consumer in mind, met by thinking,
not by building a second frontend.

**Provider interface (durable, core-owned contract; D8).** *Given a conversation +
the available tools, stream assistant output and tool-call requests.* Concrete
providers absorb one service's wire specifics and are swappable by construction.
For Claude we split along the **shared inference core ↔ auth face** line, *not* one
monolith: a **shared Claude inference module** (Messages-API request shaping, SSE
stream parsing, mapping Claude's output + tool calls onto `agent.*` events,
tool-schema translation) plus a thin **provider face** over it that owns only its
**auth strategy** (`claude-api` — the Anthropic API key, the `x-api-key` header).
The split is not over-engineering for one face: it keeps the durable inference code
free of any one credential scheme, so an alternative *sanctioned* auth strategy
could be added later as another face without touching it. The face rides the *thin*
protocol-participant seam (D8 phasing): a plugin *architecturally* (behind the
interface), loaded in-process until the full plugin platform (D17–D19) exists, at
which point it becomes a real plugin sharing the inference module with **no
interface rework**.

**MVP scope — read + propose-edit only.** The agent may read the project (existing
`fs.*` / `buffer.*` ops) and *propose* edits the user applies or rejects through
the diff→apply review UX (D20). Reads **auto-execute** — they are inspection, not
mutation, so the agent reads freely and each call renders as transparency; the
approve/deny gate is reserved for the *write* surface. Command execution
(`exec.run`) and its allow-list / confirmation guardrails are **out of this slice**
(O4), so we get a useful, dogfoodable agent without the dangerous surface. The
**read tool-loop is built — slice 4**; see the status note below.

**Auth — the official Anthropic API key (`claude-api`), and only that.** The face
authenticates with a pay-per-token Anthropic **API key** sent as the `x-api-key`
header against the documented Messages API — the only **sanctioned, stable,
ToS-compliant** path for a third-party integration. The key is stored as a 0600
secret (D21); no system prompt is forced and no beta header is sent — it is the
plain, supported request.

> **Rejected — the claude.ai subscription OAuth path (eyes open, then removed).**
> An earlier increment prototyped signing in with the user's claude.ai
> *subscription* via OAuth, the way Anthropic's own Claude Code does. It was
> **removed and will not be revived.** Making the Messages API accept a
> subscription token requires the request to **impersonate Claude Code** — a forced
> `system` prompt *"You are Claude Code, …"* plus an `anthropic-beta: oauth-…`
> header. That is an undocumented path that runs against Anthropic's ToS and can be
> revoked without notice. **rio will not ship code or architecture that depends on
> violating a SaaS provider's ToS** — it sheds a bad light on the project and rests
> on a foundation we don't control. Any future alternate auth must be a *sanctioned*
> mechanism. (The generic browser/PKCE/loopback plumbing built for that path was
> removed with it; nothing in the supported API path needs it.)

**Resilience.** The API path is documented and stable, so the "break without
notice" pressure is far lower than the rejected OAuth path faced — but the same
discipline still applies and is cheap:
- **Wire specifics are config data, not baked code** — endpoint, model, API
  version live in an overridable config block, so a model bump or version change is
  a one-line edit, not a rebuild. *(Later: the request-timeout budget joined the
  config too — `request_timeout`, forwarded into the transport request. The whole
  streaming turn shares one HTTP budget, so the default is deliberately generous
  (10 min): a long generation or a multi-tool round-trip must not be severed
  mid-stream and mislabelled a network failure.)*
- **Failures are classified and actionable, never silent** — distinct,
  plain-language `agent.error` states for *not-configured* ("add a key in Settings ▸
  Claude API key"), *auth rejected — 401/403* ("check your API key"), *rate-limited
  — 429*, *server — 5xx*, *network/TLS*, and the catch-all *unexpected response
  shape* ("the integration may need an update") — each enriched with the API's own
  error detail. Always name the next action.
- **Fail closed and contained** — a provider blow-up surfaces as `agent.error`
  (D10 async, D20 guardrails); the chat pane stays usable and editor/git are
  untouched.

**Why:** lands a real, dogfoodable agent on the seam we already designed (D8/D20)
without building the deferred plugin platform; the read-only MVP defers the
dangerous guardrail work; and shipping only the **sanctioned API-key path** keeps
rio on a foundation it controls and can stand behind. MCP alignment of the provider
and agent-tool interfaces remains open (O12).

**Status:** core slice **implemented** — `rio-core/agent.tcl` (the orchestration
loop, the provider interface, and the echo stub provider), `rio-core/ops-agent.tcl`
(`agent.send` as the first streaming op via `register_stream`, plus `agent.reset` /
`agent.history`), the streaming dispatch path (`rio::dispatch::register_stream` +
`rio::core::call_stream` — a streaming handler gets the live `emit`, returns an
ack, and emits agent.* events from a coroutine), and the `agent.history` wire
encoder. The streaming model is verified both in-process and over the socket
*broadcast* (the same loop, D2). The **GUI chat pane** (slice 2) is implemented too
— the right-hand `chat` column as a dumb view over the event stream, driven
end-to-end by the echo provider (see the "GUI agent chat pane — implemented" note
under O2). The supporting **secrets store** (`rio-core/secret.tcl` — 0600 files
under the data dir, apart from settings/session) is in place and tested. The
**shared Claude inference core + the `claude-api` face** are implemented and tested
**offline** behind a transport seam: `plugins/claude/inference.tcl` (request
shaping, the SSE→`agent.*` mapping, and HTTP-status error classification per D26),
`plugins/claude/api-face.tcl` (the `x-api-key` auth + key storage + the provider,
config-as-data), and `plugins/claude/transport.tcl` (the real tcltls streaming
transport, CA-verified). Tests stream a *faked* Claude reply all the way through
the real agent loop. The earlier **claude.ai OAuth prototype was removed** (faces,
PKCE/loopback plumbing, and the Claude-Code system spoof) — see the *Rejected*
note above; rio ships only the sanctioned API-key path. The **GUI is now wired**
(slice 3): a *Settings* menu selects the live provider (echo ↔ claude-api) and
names it in the chat header, and *Settings ▸ Claude API Key…* opens a modal that
stores/clears the key through the face's 0600 secret store (the dialog never holds
the key itself). Selecting Claude with no key isn't blocked — the first turn then
surfaces the face's actionable `not_configured` error, pointing back to Settings.
The headless GUI smoke drives all of this against a throwaway secret dir (provider
swap, the no-key error path, and key save/clear incl. the 0600 mode).

The **read-only tool round-trip is implemented (slice 4)** — the safe half of the
agent's tool surface (O4), built before anything that writes to disk. The core
gains a tool registry/executor (`rio-core/agent-tools.tcl`, `rio::agent::tools`)
exposing four read-only built-ins that wrap existing ops: `fs_list` (browse the
project tree), `fs_read` (read *any* project file — a new read-only `fs.read` op in
`ops-fs.tcl` that returns a file's text with **no** buffer/tab side effect),
`buffer_list`, and `buffer_text` (the live, possibly-unsaved text of an open
buffer). Tool execution stays in **core** (D20: the security boundary), is
**read-only by construction** (only read ops are registered), and is fenced by two
rails — path inputs are **confined to the project root** (an absolute or
`../`-escaping path is refused unread) and each result is **size-capped**. The
orchestration loop (`agent.tcl`) became a **tool loop**: the provider contract
gained `post tool <id> <name> <input> <raw>` and `post done ?stop_reason?`; on
`stop_reason tool_use` the loop auto-runs the tools, feeds `tool_result`s back as a
follow-up turn, and re-invokes the provider until the model finishes (a step cap
bounds runaway loops). Conversation entries generalized to Claude **content
blocks** (text / tool_use / tool_result) so a turn's tool exchange survives the
re-send; `agent.history` still flattens to a readable `{role,text}` transcript. Two
new **terminal-aware** events carry the activity — `agent.tool {turn,id,name,args}`
and `agent.tool_result {turn,id,name,ok,summary}` — which the chat pane renders as
muted transparency lines (red on a refusal), *not* as a permission prompt. The
shared inference core now sends the `tools` array and parses Claude's streamed
`tool_use` blocks (`input_json_delta` accumulation + `stop_reason`). All of it is
tested offline: the agent loop against a fake tool-using provider (the
call→execute→result→final-message round-trip, the containment refusal, and the
clean history), `fs.read`, and the inference tool-use SSE path. The read
round-trip is **verified live** against `api.anthropic.com` (the dogfood moment) —
a real turn lists the project, reads a file, and answers, with the containment
refusal holding; a request-body `\u`-escape fix (`_jstr`) was needed so a
tool_result carrying a file's non-ASCII text survives transport encoding.

The **write/propose-edit half is implemented (slice 5)** — the dangerous tool
surface (O4), gated by user approval. It is **general agent/core work, not
provider-specific**: the Claude plugin needed **no change** (its inference core is
tool-agnostic), so the same gate serves any provider. The agent gets two **write**
tools alongside the reads — `propose_edit {path, old_string, new_string}` (a
unique-match find/replace, with *not-found* / *not-unique* refusals in the
Claude-Code Edit discipline) and `propose_create {path, content}` (a new file;
parents made on apply) — registered in `rio::agent::tools` with `kind write`.
Unlike reads, a write **never auto-runs**: the loop calls `prepare_write` (locate
the match, build a review diff), emits **`agent.propose {turn,id,name,path,diff}`**,
and **suspends the turn's coroutine** until the new op **`agent.approve
{turn,decision}`** resumes it (a `pending` turn→coroutine registry; `agent.reset`
aborts a waiting turn). On *approve*, `apply_write` edits an open buffer through
`buffer.replace` (undoable; its `buffer.changed` is forwarded on the turn's emit so
the editor updates live) and, by default, persists via `file.save`; a closed file
or a create is written straight to disk through the new **read-only-sibling
`fs.write`** op (root-confined, `mkdir -p`). On *reject* the model gets a plain
"rejected" tool_result and the turn continues. Two policy flags are **data** so a
later setting can flip them: `apply_writes_disk` (default on — apply *and* save)
and `auto_accept` (default off — when on, the gate is skipped). The GUI renders the
diff (+green/−red) and raises an **Approve/Reject bar** wired to `agent.approve`,
with a *Settings ▸ Auto-accept edits* toggle; an applied edit to the visible buffer
updates through the existing `buffer.changed`→`apply_change` path. All paths are
tested offline (approve/reject round-trips, auto-accept, the stale-approve error,
the prepare refusals, `fs.write` incl. parent-dir creation) and the Claude suite is
**unchanged** — the proof it's provider-agnostic. **Remaining:** a live write
against `api.anthropic.com`, and the exposed-as-config UI for the write policy.
*(The run-command tool landed later as **D83** — gated, async, timeout-bounded —
then **D84** added an opt-in, human-authored allow-list: standing approval that skips
the bar for commands the user marked trusted, still human-in-the-loop per D53.)*

**Amendment — an approved write re-resolves its target (landed).** The gate had a
time-of-check/time-of-use hole: `prepare_write` located the edit's coordinates when
the proposal was *built*, but the editor stays live while the turn's coroutine waits
at the approval gate — so typing in the buffer before clicking Approve made the edit
land at stale coordinates (and a create could silently overwrite a file that appeared
meanwhile). Now the plan carries `old`/`new` rather than frozen positions, and
`apply_write` re-resolves the ground truth when the decision arrives: it re-reads the
file's *current* text (live buffer or disk — also re-deciding which, since the file
may have been opened or closed in the interim), re-locates `old_string` under the
same unique-match contract the user reviewed, and applies at the fresh position — so
an edit elsewhere in the buffer merely moves the match, while a vanished or ambiguous
match (or an appeared file, for a create) is **refused** with a "changed since
proposal — re-propose" tool_result instead of ever applying at the wrong spot.
Covered by three agent.test cases (stale-refused, moved-match-applies,
create-appeared-refused).

### D27 — UI iconography: monochrome Unicode glyphs (no raster/`.ico`, no emoji)

The handful of iconic affordances in the GUI use **monochrome Unicode symbol
glyphs**, not raster icons. This is already the established idiom — the tab close
`×`, the `·` separators, `→`, and the `•` key mask are all glyphs — so it is a
decision to *keep* and lean into, not a new mechanism. Glyphs cost zero assets,
inherit the theme foreground (they color and recolor for free through the D24
`apply_theme` roles), and scale with the font. The one constraint: a glyph must
exist in common monospace fonts, so we stick to widely-covered code points
(`⌕ ▶ ▸ ▾ ☰ ● ○`) and fall back to a plain text label where coverage is doubtful.

**Rejected — classic Win95 `.ico`.** Tk 8.6's core `photo` reads PNG and GIF
natively but **not** `.ico` (here `image types` is only `bitmap photo` — no Img
extension). Loading `.ico` would need the **Img/tkimg** runtime dependency (or a
build-time convert), against rio's dependency-light grain; the classic
Microsoft icon set also isn't freely redistributable; and raster doesn't scale
with font size / HiDPI. **Rejected — color emoji:** Tk 8.6 has no color-emoji
rendering (tofu or monochrome), and they clash with the Acme/monospace look.

**Escape hatch (if true pixel icons are ever wanted):** ship **PNGs through core
`photo`** (alpha works in 8.6) — never pull in Img just to read `.ico`.

**Why:** matches the existing look and the from-scratch/no-dependency ethos, and
themes for free. Implementation across the remaining spots (search, run/send,
file-tree expand/collapse, modified-dot) is **deferred** — this entry only fixes
the direction.

*(Implemented 2026-07-22.)* The deferred sweep landed, converting the
remaining text-labeled iconic controls to glyphs: the tab/title **unsaved-dot**
`●` (U+25CF, a bare filename in `tab_name` + a `tab_dot` marker the tab strip
and title append — kept out of the compare picker and the save prompt, which
read cleaner bare), the find bar's **next/previous** `↓`/`↑` (U+2193/2191, the
find-widget idiom; F3/Shift+F3 remain the keys), the chat **send** `▶`
(U+25B6), and the Extensions window's **refresh** `⟳` (U+27F3, the glyph the
git pane already uses). Every glyph is plain button/label text, so it recolours
through `apply_theme` with no new role. Two things stayed by choice, not
oversight: the file pane keeps the **POSIX `name/` trailing-slash** for
directories (an idiom, not a missing icon), and the git list keeps git's own
**porcelain XY codes** (`M`/`A`/`?`…). "search" has no on-screen home yet (find
is keyboard/menu-driven, no toolbar button), so `⌕` waits for a spot to live
in.

### D28 — Compare / diff view: a core line-diff op + a read-only two-pane GUI view

D13/D14 always anticipated the editor center "splittable into two editor groups
for side-by-side / diff viewing"; this builds the **first cut**. The split is
along the usual rio seam — **the diff is computed in core, the frontend only
renders it** (D1/D3) — so a future TUI compare view consumes the same data.

**Core — `diff.lines` (the durable, terminal-aware part).** A pure-logic LCS
line diff (`rio-core/diff.tcl`, `rio::diff::lines {a b}`): given two texts it
returns the ordered op list that turns A into B, line by line — each op a flat
dict `{tag <equal|delete|insert> a <A-lineno|0> b <B-lineno|0>}` (1-based; `0` =
no line on that side; a *changed* line is a delete adjacent to an insert). It
splits on `"\n"` and normalizes `""`→one empty line **exactly like the document
model** (D12) so a diff lines up with the buffer it came from. Exposed as the
`diff.lines {a, b}` op (`rio-core/ops-diff.tcl`) with a D25 result-encoder
(`ops` is an array of flat objects). No Tk shape rides on it — the O1 discipline
of designing a rendering-heavy namespace for a cell-grid consumer, met by
thinking. Classic O(n·m) DP; fine for source-file sizes, large-file handling
out of scope as elsewhere (O3).

**GUI — the compare view (`rio-gui.tcl`).** A center region `.cmp` of **two
read-only text panes** with a shared vertical scrollbar, shown *instead of* the
editor while comparing (`place_dock` swaps `.ed`↔`.cmp`; the editor returns on
close). It is a dumb view (D3): `compare_open` calls `diff.lines` and `cmp_fill`
walks the ops once, filling both panes in lockstep — an `equal` op emits a real
line on each side, a `delete` the left line (tagged `del`) opposite a blank
`filler` row, an `insert` a `filler` opposite the right line (tagged `add`). The
**filler rows keep equal lines level across the panes** (VSCode-style alignment),
which also makes the synced scroll (shared scrollbar + a guarded `cmp_yscroll`)
exact. Each line also carries a **`-`/`+` gutter marker** (color-independent), so
the diff reads even where a Tk build renders tag backgrounds poorly under wrap —
colour is the emphasis, the marker the guarantee. Reached from
the **Compare** menu ▸ **Compare With File…** (active buffer vs. a picked
file, read via `fs.read`) and closed with a visible **× Close compare** button (a
top bar over the panes; its label names the `Esc` shortcut, which alone isn't
discoverable), **View ▸ Close Compare**, or `Esc`. The panes have no horizontal
scrollbar, so **View ▸ Wrap Lines** reaches them too (the only way to read long
lines there).

**Agent — complex proposed edits open live as compare (the VSCode-like part).**
The write/propose-edit gate (D26 s5) is unchanged; the compare view is a richer
review surface over it. A new pull op **`agent.proposal {turn}`** →
`{name, path, original, proposed}` returns a *pending* proposal's full original
and proposed text (kept in a `proposals` registry alongside the approval
`pending` one, cleared when the turn resolves or on `agent.reset`). The
`agent.propose` **event stays lean** (unchanged) — the GUI pulls both versions
on demand only when the view opens, so a TUI would too. In the chat pane a
**complex** edit (more than `compare_threshold` diff lines) auto-opens the
compare view instead of dumping the whole diff inline; a small edit stays inline
as before; a **Compare** button on the Approve/Reject bar opens it for any
proposal; approving/rejecting closes it. A **Settings ▸ Agent: Compare complex
edits** toggle disables the auto-open entirely (everything renders inline; the
button still works) — the user's explicit escape hatch.

**Deferred (noted, not built):** the right/proposed pane is **read-only** for
now — an *editable* proposed-side scratch buffer (tweak-then-apply) and a real
**tabbed second editor group** (the full D13 "two editor groups", not just a
diff surface) are later enrichments; so is the D14 narrow-tier fallback from
side-by-side to a unified diff. This first cut is the simplest honest one,
matching how the file pane (O2) was scoped.

*(Amendment — the "tabbed second editor group" deferred above is now realized by
**D33**; that split is the general editor-group mechanism. The compare view stays
its own bespoke read-only surface for now, but D33 notes the path to eventually
folding it into a read-only buffer in the second group.)*

**Conversation integrity — sealing abandoned tool calls.** Surfacing proposals
in the compare view made it easy to *abandon* one — type a new message instead of
deciding — which exposed a latent loop bug (D26): the assistant `tool_use` turn is
recorded before the loop suspends at the approval gate, so a new turn left that
`tool_use` with no `tool_result`, and Claude rejects that on the next request
(HTTP 400, "tool_use ids ... without tool_result"; the step cap had the same
hole). Fix (`rio::agent::_seal_dangling`, called by `send`): before a new turn,
abort any turn suspended awaiting approval (its coroutine must never resume into
the new conversation) and answer each dangling `tool_use` with an *interrupted*
`tool_result`, **folded into the new user message** so the assistant `tool_use`
stays immediately followed by its `tool_result` and roles still alternate. The
GUI matches by dismissing a pending proposal's review UI when the user sends
instead of deciding.

**Why:** lands a genuinely useful compare/diff surface on the seam D13/D14
already reserved, with the diff logic in core (shared with a future TUI, and a
candidate to later back the agent's `_difftext`), while keeping the GUI a dumb
renderer; the pull-op keeps proposal events lean; and the read-only first cut
defers the editor-group refactor without blocking the feature.

---

### D29 — GUI as a socket client: editor over a remote core (server mode, editor-first)

D2 made the protocol transport-independent and the socket **server** has existed
and been tested since (`rio-core/server.tcl`, `tests/server.test`): the *same*
`rio::dispatch::handle` over TCP, response to the requester, events broadcast to
all clients. What was missing was a **client** — the GUI embedded the core and
called `rio::core::call` directly. D29 makes the GUI able to drive a core running
**elsewhere** (a headless box, reached over an SSH tunnel), editor-first.

**One transport seam.** `rio_call {op params}` now dispatches on `::remote`. The
mode is chosen *before any sourcing* (so the two modes load different code):
`--connect host:port` (argv), `RIO_CONNECT` (env), or a pre-set `::connect_to`
(tests). In-process (default, unchanged) embeds the Tk-free core + the Claude
plugin and calls `rio::core::call`. **Remote** sources only the wire encoder
(`rio::wire`, Tk-free) and opens a socket; `remote_call` writes one `{id,op,params}`
JSON line (the *same* `rio::wire` escaping the server replies with) and runs the
event loop until the reply with its **unique id** lands. A `fileevent` reader
(`remote_reader`) splits incoming lines: **events → `dispatch_event`** (applied to
the view at once), **replies → the `rio_call` waiting on that id**. Unique ids make
a keystroke typed mid-wait — itself a nested `rio_call` — resolve independently
(nested `vwait` on distinct vars). A dropped socket wakes every pending call with a
`disconnected` error (no hang) and reports once. Both transports return the *same*
response dict, so no caller can tell which is live.

**Symmetric event handling.** The event switch that lived inline in `rio_call` is
now `dispatch_event {ev}`, fed by both transports (in-process from the call's
returned events, remote from the reader). `buffer.changed` redraws the editor only
when the changed buffer is the **active** one (matching `agent_event`'s guard) — the
rule that lets an async remote event for a background buffer be ignored safely.

**No more reaching past the protocol.** Two in-process shortcuts are gone so both
modes use ops only: `rio::doc::text $id` → the **`buffer.text`** op (`buf_text`),
and the startup `$::rio::ops::default` → **`buffer.list`** adoption
(`adopt_initial_buffers` registers every reported buffer and activates the first;
`buffer.new` if none). In-process reports its own default buffer; remote reports the
server's open buffers — same code.

**Remote file access is server-side.** The filesystem of record is the **core's**.
The native choosers (`tk_getOpenFile`/`tk_getSaveFile`/`tk_chooseDirectory`) browse
the *client* disk, so in remote mode they give way to a typed **server-path** prompt
(`remote_path_dialog`); the **file-tree pane** (`fs.list` + `project.open`, already
ops) is the point-and-click way in, unchanged. A path on the command line opens as a
project folder (we can't stat a server path from the client). *(Later: the typed
prompt became a full point-and-click **`remote_browse_dialog`** — it walks the
server's tree over the same `fs.list` op the file pane uses, so the choosers
browse the remote disk directly, with an editable Location bar that keeps the
typed-path jump; this subsumed and retired `remote_path_dialog`. See D30 below.)*

**Agent stays in-process this pass.** Its provider/key/policy plumbing isn't ops
yet, so in remote mode the chat column is hidden and its menu entries greyed; the
editor, file tree, git, and compare view all run fully over the socket.

**Server binds loopback by default.** `rio::server::listen` now binds **127.0.0.1**
unless asked otherwise (`--any`, or `RIO_BIND=0.0.0.0`, which also prints a no-auth
warning): the core has no auth or encryption (the SSH-tunnel model), so it must not
face the public interface unasked.

**Two honest caveats (inherent, not bugs).** (1) **Per-keystroke round-trip**: the
GUI is a dumb view (D3), so a keystroke is a `buffer.replace` whose echoed
`buffer.changed` draws the character — one RTT each over the socket. Fine on
localhost / a nearby box through an SSH tunnel; laggy across the world. A local-echo
optimization is possible later. (2) **Files live on the server.** Verified by a new
end-to-end socket smoke (`rio-gui/tests/remote.tcl`): an in-process server + the GUI
in remote mode over a real socket — open/edit/save/undo/redo/compare, asserting the
widget mirrors only because a `buffer.changed` round-tripped the wire and the
server's own document and on-disk bytes agree.

**Out of scope (named, not built):** agent-over-socket (provider/key/policy ops +
loading the Claude plugin server-side), auth, encryption (SSH provides both),
reconnect/resume, multi-client conflict UX, and the local-echo latency win.

**Why:** the protocol was built for this (D2); the missing half was a client. Adding
it as one `rio_call` seam — rather than a parallel frontend — keeps the in-process
path (the common case) unchanged and the remote path a thin reroute, while finally
exercising the wire layer end-to-end from a real GUI. Editor-first lands the useful
80% (remote editing over a tunnel) without dragging the agent's credential model
onto the server yet.

---

### D30 — Frontend is always a client to a core over a channel (pipe local, socket remote)

D29 made the GUI *able* to attach to a remote core but left **two transports**: an
in-process default and a socket. That split is the redundancy network transparency is
meant to remove — and, for the agent's coming write/exec powers, a loopback socket
with no auth is a real hole on a shared host (SSH guards the network hop, not the
loopback endpoints on either end). D30 collapses to **one transport**: the frontend is
*always* a client to a core at the far end of a **channel**, never embedding it.

**Two channel kinds, one client path.** (1) **Default — a pipe to a spawned child
core** (`tclsh rio-core/server.tcl --stdio`): requests on its stdin, responses +
events on its stdout (the LSP / git-over-ssh model). Local, so the core's filesystem
is ours and it runs as us; **no listening socket exists**, so there is nothing on a
shared host to connect to and process ownership is the access control. (2)
**`--connect host:port` — a TCP socket** to a listening core (the optional
persistent-daemon mode, D29's server), loopback by default. The same `rio_call` seam
(`core_call` / `core_reader` / `core_lost` over `::core_chan`) drives both; there is
**no in-process code path**, so local and remote are the same code — true network
transparency.

**Why pipes, not unix sockets or a cookie.** The goal was secure local IPC with no
network surface. Unix domain sockets would do it, but **core Tcl is TCP-only**
(8.6–9.0; AF_UNIX needs a compiled C extension) — a build dependency we won't take. A
loopback-TCP + capability-token (cookie) scheme would also work but adds an auth
protocol and token-distribution friction. A **pipe to a child** needs none of it: no
socket, no auth, no crypto, pure stdlib — and for the remote case the *same* child is
reached through `ssh host … --stdio`, so **SSH provides authN + encryption** (extending
D29's "leave encryption to SSH" to transport + authentication). The listening TCP
server survives only as an opt-in daemon for several frontends on one core; that is
the one place a cookie would later be added.

**Filesystem of record.** A spawned local core shares our filesystem, so the GUI keeps
native file choosers there; a `--connect` daemon may be elsewhere (e.g. SSH-forwarded),
so it browses the server's disk over `fs.list` (`::core_remote` → `remote_browse_dialog`;
originally typed-only server paths). The file tree is the point-and-click way in either
way — and now so are the Open / Save As / Open Folder dialogs.

**Lifecycle.** Closing the channel ends the session: a spawned child sees EOF on stdin
and exits with the GUI (verified even on an abrupt kill); a daemon just drops the
connection. A vanished core wakes every pending call with a `disconnected` error
rather than hanging.

**Landed vs pending.** *Done:* the core `--stdio` transport (`rio::server::serve_stdio`)
and the GUI's single channel transport (default spawn + `--connect`), with
`rio-gui/tests/{smoke,remote,pipe}.tcl` covering the socket-backed and real
pipe-spawn paths. *Done — the agent over the channel (P3):* the agent is a core
concern, so it now lives wherever the core runs. The spawned core **loads the Claude
plugin** (`server.tcl` sources `plugins/claude/claude.tcl`), which **self-registers**
in a new **named-provider registry** in `rio::agent` (`register_provider name cmd
?-key …?`): `echo` is built in, `claude` registers itself with a *key capability*
(set/clear/status) so the agent layer stays credential-blind. Provider, key, and
policy are now **ops** — `agent.provider.set {name}`, `agent.key.set {key}` /
`agent.key.clear`, `agent.autoaccept.set {on}`, and `agent.status` (provider /
auto_accept / key_set) — so a frontend (local **or** remote) drives them identically;
the API key lives in the **core's** 0600 store (D21) wherever the core runs (run the
core locally if you won't put a key on a given box — the GUI is the same either way).
*(Later: the GUI **adopts** this state rather than imposing its own. At startup and
after an in-place reconnect it READS `agent.status` and mirrors provider +
auto-accept into the Settings menus (`adopt_agent_status`); it only WRITES
(`agent.provider.set` / `agent.autoaccept.set`) on an explicit user action. It used
to push its boot default (`echo`, gated) at attach time, which would silently reset
the live provider of a daemon another client had already configured.)*
`agent.send` stays a streaming op, but its events are now **ordinary broadcast
traffic**: they arrive on the GUI's one channel reader and `dispatch_event` routes
`agent.*` to the chat — there is no separate in-process streaming sink. The chat is
**no longer hidden** (`::agent_avail` retired); the smoke exercises a full turn over a
socket and `pipe.tcl` a full turn over the real spawned-child pipe. **Deploy
consequence:** the agent's Claude HTTPS now runs *server-side*, so a headless core
box needs `tcl-tls` too — `rio-server-deploy.sh` installs it and the verifier checks
`package require tls` (a pre-P3 server, provisioned TLS-free, fails a Claude turn with
"can't find package tls"). *Done — connect from a running GUI:* attaching to a daemon
is no longer launch-only — **File ▸ Connect to Remote Core…** prompts for a
`host:port` and, by default, **rewires the current window in place** (open the new
socket first, save-check the open tabs, then drop the local core, swap `::core_chan`,
and re-adopt from the remote core — a failed connect or a cancelled save leaves the
live session untouched); an **"Open in a new window"** checkbox instead spawns a
second `rio-gui --connect …`, reusing the startup path. Covered by
`rio-gui/tests/reconnect.tcl` (a real second daemon, the dead-port safety property,
and the live swap). *Done — native remote browsing:* in remote mode the Open / Save
As / Open Folder (and Compare-with-file) choosers are a point-and-click
**`remote_browse_dialog`** that walks the core's filesystem over `fs.list` (the docked
file pane's op — `..`, dirs, then files; dir-only in folder mode) with an editable
Location bar for a known path, so you never type a blind server path. It retired the
typed-only `remote_path_dialog`; `rbrowse_rows_for`/`rbrowse_start` are split out for
headless testing, covered by `rio-gui/tests/browse.tcl` (the fs.list walk, the
navigate/choose logic per mode, and a real-modal build/teardown). *(Later hardened:
`rbrowse_go` / `remote_browse_dialog` now bail cleanly if the dialog is cancelled while
its `fs.list` is in flight — an Escape during a slow remote listing no longer crashes
the proc.)* *Pending:* a
`--ssh host [path]` convenience wrapper (P4) —
today the remote path is `--connect` over a hand-made `ssh -L` tunnel, or
`ssh host … server.tcl --stdio` by hand.

*(Follow-on — a bounded handshake, so a stale tunnel can't hang the window.)* A dead
`ssh -L` forward is worse than a refused connection: `socket` **succeeds** (the local
end accepts), but nothing answers behind it and no EOF ever arrives, so an unbounded
`vwait` on the first op left the GUI frozen on a blank window — no error (a real report).
Fix: `core_call` takes an optional deadline; `hello_core` (now the **first** op on any
live channel, at startup and after reconnect) runs it with an 8 s bound and doubles as
the liveness gate. On timeout it says why — at startup *fatal*, a clear dialog then exit
(nothing to fall back to); on reconnect non-fatal, leaving the old session up. A late
reply after a timeout is dropped (`core_reader` only wakes a call still `::pending`), and
`session.hello` finally earns its keep as more than a protocol-version check (retires the
review's B1: it was defined and tested but never called). `rio-gui/tests/remote.tcl`
covers it with a listener that accepts but never replies. View/transport only — the core
and wire are untouched.

**Caveats (inherent).** Per-keystroke round-trip (the D3 dumb view) — imperceptible
over a local pipe or a nearby tunnel, laggy across the world; and **one core per
frontend** (no shared live state across windows — that is the daemon's job).

**Why:** one transport kills the in-process/remote redundancy, and having no default
listening socket removes the shared-host exposure *structurally* rather than patching
it with auth — the POSIX-purist answer (compose with SSH and pipes). The wire layer
(D2/D11) already let the core speak this; the GUI just stopped being a special case.

---

### D31 — Sessions & preferences: resume a working space, split by owner, out of tree

Realizes the **session/workspace** half of D21 (and revises its storage), so launching
rio at a project brings back *how the editor looked* and *what you had open*. The key
move is splitting what D21 lumped together — "recent files, window/pane sizes, open
tabs" — by **who owns it**, because the D30 client/core split makes that ownership
matter:

- **Preferences** — theme, line-wrap, dock side/pane, chat visibility. *Pure view
  state* the core knows nothing about, so the **GUI owns it**, in
  `$XDG_CONFIG_HOME/rio/prefs.json` (beside the user themes dir). Plain JSON, parsed
  never executed (D21). Loaded at startup over the defaults; saved on each change
  through the one applier per setting (`do_theme`, `apply_wrap`, `place_dock`,
  `show_pane`). A missing/corrupt file, or a persisted theme that no longer exists,
  falls back to defaults rather than stopping startup.
- **Workspace** — the open files (in tab order) + the active tab, **per project**.
  *Document state*, so the **core owns it**: the `workspace.*` ops
  (`workspace.save` / `workspace.get`), keyed by the open project root, store it **out
  of tree** under `$XDG_DATA_HOME/rio/sessions/<md5-of-root>.json`. Because the store
  lives with the core, a resume **Just Works over a remote core** — the session follows
  the project onto the server (D30), like the files it names. `workspace.get` prunes
  paths that have since vanished (so a resume never spams "can't open") and no-ops when
  no project is open.

**Out of tree, not `.rio/`.** D21 sketched a per-project *in-tree* `.rio/` dir for
project-local session; D31 keeps the *session* out of the repo instead — keyed by root
under the data dir — so it never shows in `git status`, needs no `.gitignore`, and
can't be committed by accident. (A `.rio/` for *shared, committable* project settings
can still land later; that is a different thing from personal resume state.) Window
geometry and pane pixel-widths are deliberately deferred (flaky across multi-monitor,
low payoff) — an easy later extension.

**Ownership boundaries respected.** Neither store ever holds a secret (the API key
stays in the 0600 store, D26). Active-tab / tab-order is frontend-local (D22), so the
GUI supplies it; the core only persists what it is told, keyed by the root it owns. The
open-file list crosses the wire *inbound* as a newline-joined string (params are flat
strings, and a path holds no newline — the conf format assumes the same) and returns
*outbound* as a proper JSON array (a shape-aware encoder, D25).

**Implemented:** `rio-core/workspace.tcl` (the pure keyed store) + `ops-workspace.tcl`
(root-keying, stale-path pruning) + the `workspace.get` wire encoder (D25); GUI side in
`rio-gui/rio-gui.tcl` (`prefs_load` / `prefs_save`, `session_save` / `session_restore`,
gated on a `::rio_started` flag so the boot-time appliers don't persist defaults over
what was just loaded; restore runs after the argv folder opens). Tests:
`rio-core/tests/workspace.test` (store round-trip, keying, pruning, corrupt-file
tolerance, the wire shape) and `rio-gui/tests/session.tcl` (prefs round-trip + the boot
guard, and a full open → save → restore cycle through the spawned core). A shared
`rio-gui/tests/sandbox.tcl` points every GUI test's XDG dirs at a throwaway path so the
suite never touches (nor leaks into) the user's real config.

**Why:** resume is table-stakes for "pick up where I left off," but the naive
one-file-in-the-project-dir version breaks the moment the core is remote — view state
is the client's, the open-file set is the project's. Splitting by owner puts each half
where it already belongs (config dir vs the core's data dir), makes remote resume fall
out for free, and keeps the repo clean.

---

### D32 — Syntax highlighting: pure swappable tokenisers in the frontend, colours as theme roles

Highlighting is **presentation, not document state** — like the cursor and selection
(D22) and the theme *applier* (D24), it is a frontend concern, so the tokenisers live in
the **frontend**, not the core. (Considered and rejected: tokenising in the core and
broadcasting spans on `buffer.changed`. It would hand every frontend highlighting for
free, but it puts a per-edit round-trip in front of *colour* — visibly laggy over a
remote core (D30) — and adds span encoders and viewport plumbing to the core, all to move
a pure function that needs no core-only state.)

The split mirrors themes exactly (D24 — *the core owns the data, the GUI applies it*):

- **The core owns the syntax colour ROLES** (data): the `syntax.*` entries in the theme
  role table (`syntax.comment`, `syntax.string`, `syntax.tag`, …). They ride in the same
  table every theme inherits, so a theme harmonises highlighting to its own palette, a
  theme predating D32 inherits the default set (never "no colour"), and a future TUI maps
  the same roles onto a terminal palette. No parser change — a theme file overrides them
  as ordinary `[colors]` entries.
- **The frontend owns the TOKENISER + the applier.** A tokeniser is a **pure, Tk-free
  module** (`syntax/<lang>.tcl`) that turns text into a flat list of `line.col line.col
  type` spans (D12's shared position format — exactly what a Tk text tag consumes). It
  carries its own multi-line state so the result is context-correct. The GUI applier maps
  each span TYPE onto the theme's `syntax.<type>` colour as a `syn:<type>` text tag, and
  re-tokenises the active buffer after an edit; a theme switch just reconfigures the tag
  colours, so highlighting recolours live for free.

**Swappable, and no external packages.** A highlighter registers itself for a set of file
extensions through `syntax/registry.tcl` (the contract + the canonical token vocabulary).
Shipped modules load first, then the user's own from `$XDG_CONFIG_HOME/rio/syntax/` (D21
locations), and a later registration for an extension wins — so dropping in a better
`perl.tcl` shadows the shipped one, the same override idea as user themes. Modules use
core Tcl only (`string`/`regexp`/`dict`); a broken one is reported and skipped, never
fatal. Because a module is Tk-free it is genuinely portable — the future TUI reuses the
identical files with its own applier, so the logic never forks.

**Pure, so testable headless.** The tokenisers run under a bare `tclsh`
(`syntax/tests/all.tcl`), no display required.

**v1 scope.** First language: **(X)HTML** (`syntax/html.tcl`) — comments, the doctype and
processing instructions (`meta`), element names + angle brackets (`tag`), attribute names,
quoted values (`string`), `&entities;`, and `<script>`/`<style>` bodies treated as raw so
an inline `<` in JavaScript never spawns a phantom tag. The GUI re-highlights the **whole
active buffer** per change (correct multi-line context), coalesced on the idle handler so
a burst of keystrokes paints once; **viewport/incremental** scoping is a noted later
refinement (as undo-coalescing is in the doc model). *(**Amended below** — the per-change
re-highlight is now **incremental**; only the one-time viewport question remains deferred.)*
Only the main editor is highlighted for now (not the compare panes). A file with no
registered highlighter, or a scratch buffer with no path, simply shows plain text.

**Implemented:** `syntax/registry.tcl` (the registry, `for_path`, the token vocabulary) +
`syntax/html.tcl` (the (X)HTML tokeniser) + the `syntax.*` roles in `rio::theme::default`
and the three shipped themes; GUI side in `rio-gui/rio-gui.tcl` (`hl_load` at boot, the
`syn:*` tag config in `apply_theme`, and `hl_select` / `hl_rehighlight` / `hl_schedule`
hooked into `load_buffer` and `apply_change`). Tests: `syntax/tests/html.test` (the
tokeniser + registry, pure `tclsh`) and `rio-gui/tests/highlight.tcl` (the applier end to
end — tags painted from an opened file, plain files left untagged, a live edit
re-highlighting, a theme switch recolouring the tags).

**Why:** highlighting has to feel instant and harmonise with the theme, and it must be
easy for someone to write or replace a language without touching the core. Putting the
*data* (colours) with the core's theme table and the *pure logic* (tokenisers) in
swappable frontend modules gets all three — instant local paint, theme harmony, and a
drop-in extension point — while honouring the D30 client/core split and the D22/D24 rule
that rendering is the frontend's job.

**Amendment — incremental re-highlighting (landed).** The v1 "re-highlight the whole
active buffer per change" is retired: an edit near the top of a long file was O(buffer)
work each keystroke-burst. Two changes:

- **The contract is now a per-line SCANNER**, not a whole-buffer function: a highlighter
  provides `<ns>::scan {line state param} -> {spans nextstate nextparam}`, scanning one
  line and returning its column spans plus the scan state *entering the next line* (the
  start state is `rio::syntax::start` — the empty pair; a scanner treats state `""` as
  "start of document"). Per-line is the natural unit for a state machine and it is *less*
  code for the author (no whole-buffer loop). The whole-buffer `rio::syntax::tokenize {scan
  text}` still exists but is now **derived** by the registry driving the scanner, for the
  tests and any non-incremental consumer. `(X)HTML`'s existing per-line `_scan_line` simply
  became the public `scan` — the change was mechanical.
- **The GUI re-highlights incrementally.** It caches, per line, the scan state entering
  that line (`::hl_enter`). A **full** pass (`hl_full`) runs only on open/switch and builds
  the cache. On an edit (`hl_edit`) it splices the cache to stay index-aligned with the
  widget (from the change's first line + net line-count delta), then `hl_incremental`
  re-scans from the first dirty line **downward and stops as soon as — past the edited
  region — a line's fresh entry state equals the cached one**: the state has re-converged,
  so every line below is unaffected. Typing thus re-tags a line or two; an unclosed comment
  opened at the top correctly repaints to the end and no further. Still coalesced on idle.

**Viewport** scoping (painting only the visible window, extending on scroll) stays deferred
*on purpose*: incremental already removes the per-edit whole-buffer scan, which was the
actual cost. Viewport would only cap the **one-time** open scan on very large files, and it
needs scroll-event machinery and a paint-frontier watermark the editor doesn't yet need —
not worth the complexity against rio's "small and simple" budget until a real large-file
pain shows up.

**Implemented (amends the list above):** `syntax/registry.tcl` now defines the per-line
`scan` contract + `scan_line` + `start`, with `tokenize` derived; `syntax/html.tcl` exposes
`scan`. GUI side, `hl_rehighlight` is replaced by `hl_full` / `hl_incremental` / `hl_edit`
(+ helpers `hl_paint_line`, `hl_linecount`) over the `::hl_enter` cache; `apply_change`
calls `hl_edit`, `load_buffer` calls `hl_full`. Tests: `html.test` gains the `start` + the
per-line `scan` contract cases; `highlight.tcl` gains incremental-scope checks (a local
edit re-scans ≤2 lines via `::hl_scanned`; a top-of-file comment propagates to the end and
back; a line delete keeps the cache aligned).

**Amendment — the active language shows in the status bar (landed).** The bottom status
strip now reports which highlighter is in effect (e.g. `HTML`), or `plain text` when the
file type has no highlighter — the same VSCode-style affordance, at a glance. To feed it,
the registry gains a name lookup that parallels `for_path`: `register`'s first argument is
now a **human-readable language display name** (so `syntax/html.tcl` registers `HTML`, not
`html`), stored in a new `ext -> name` map with the same "later registration wins" /
case-insensitive matching, and `rio::syntax::lang_for_path {path}` returns it (`""` = none).
GUI side, `hl_select` records `::hl_lang` beside `::hl_scan` and `refresh_status` renders it.
The `langs` introspection dict (previously unused) is keyed by this name. Tests: `html.test`
gains `lang_for_path-*`; `highlight.tcl` asserts the status bar shows `HTML` for an HTML file
and `plain text` for a `.txt`.

**Amendment — CSS and JavaScript ship (landed).** Two more languages, exercising the same
per-line scanner contract with nothing added to the registry or the GUI (the drop-in loader
picks them up by extension). Both stay inside the D32 token vocabulary — no new colour roles,
so every existing theme highlights them for free.

- **`syntax/css.tcl`** (`.css`) — comments (`/* */`, multi-line), at-rules (`@media`, …) as
  `keyword`, strings, numbers/units and `#hex` colours as `number`, `!important` as `keyword`,
  **property names** inside a block as `attribute`, and function names (`url(`, `calc(`, …) as
  `function`. **Selectors are tinted**: element names (and `*`) as `tag`, `.class`/`#id` as
  `type`, `:pseudo`/`::element` as `variable` — but *not* inside a nesting at-rule's prelude
  (`@media screen and (…)`), where those words are a media query, not selectors (keyed off the
  same `at` flag that decides the block kind). A `#id` in selector context tints as an id, and
  is deliberately *not* mis-read as a hex colour. It tracks block structure so a property is
  only coloured where a property goes, and a small nesting-at-rule set resolves
  `@media { .x { … } }` (rule-list vs declaration block) correctly. Value keywords stay plain
  **on purpose** — CSS has too many bare value identifiers to colour without guessing.
- **`syntax/js.tcl`** (`.js .mjs .cjs .jsx`) — line (`//`) and block (`/* */`, multi-line)
  comments, `'`/`"` strings and backtick **template literals** (multi-line) as `string`,
  numbers (hex/oct/bin/float/exp/bigint) as `number`, reserved words as `keyword`, the
  literals as `constant`, and a called/defined identifier (`name(`) as `function`. **Regex
  literals are intentionally not recognised** — `/…/` is indistinguishable from division
  without a real parser, so it reads as plain text rather than risk mis-stringing a whole
  line; noted as the one honest gap.

Tests: `syntax/tests/css.test` and `syntax/tests/js.test` (pure `tclsh`, run by
`syntax/tests/all.tcl`) — property/value/number/function colouring, selector tinting
(element/class/id/pseudo) with media-prelude suppression, at-rule nesting, multi-line
comments and strings/templates, and the deliberate non-colourings (`#id` never a hex
colour, `/` never a comment).

**Amendment — Perl ships (landed).** `syntax/perl.tcl` (`.pl .pm .t .pod .psgi`), again on
the same contract with no registry/GUI change. Perl's grammar is famously not cleanly
tokenisable, so this follows the same discipline as the JS regex gap: **colour the
unambiguous, leave the rest plain rather than guess wrong.** It colours `#` comments (with a
`$#array` guard) and `=pod … =cut` POD blocks as `comment`; **sigil variables**
(`$scalar @array %hash &sub`, plus `$_`, `@_`, `$1`, `$!`, `${…}`, `$#a`) as `variable` — the
signature Perl look, and the reason `%`/`&` are only a variable when a name follows (else
they're modulo/bit-and, left plain); numbers (hex/oct/bin/float, `_` separators); declaration
/control/named-operator words as `keyword` and a curated built-in set as `function`; a
`Foo::Bar` bareword and a `sub`/`package` NAME as `type`/`function`; and the **quote-like
operators** `q qq qw qr qx m s tr y` (the operator word as `keyword`, the delimited body as
`string`) via one engine handling same-char (`/…/`) and bracketed (`() [] {} <>`) delimiters,
one- and two-part (`s/…/…/`), with multi-line carry. **Deliberate honest gaps** (nothing
mis-coloured): here-docs (`<<"EOF"`) and a *bare* `/regex/` without a leading `m` — the `/` is
division-ambiguous, exactly the JS case — read as plain text; `__END__`/`__DATA__` ends
highlighting for the file tail. One Tcl-specific lesson worth recording: a literal `}`/`]`/`;`
inside a *braced* proc body or an inline `[list …]` breaks Tcl's own brace/command parsing, so
the delimiter-exclusion set is held in a double-quoted namespace string that `_isdelim`
searches. Tests: `syntax/tests/perl.test` (24 cases) — sigils incl. the `$#`/modulo
distinctions, POD carry, the quote-like engine (same-char + bracketed, one/two-part,
multi-line), and the two deliberate non-colourings (`/` as division, `__END__` tail plain).

**Amendment — Tcl ships, and highlights rio's own source (landed).** `syntax/tcl.tcl`
(`.tcl .tm .test .itcl .tk`), same contract, no registry/GUI change. Tcl's two notorious
gotchas *are* the design, and both come from the same fact — a bareword's meaning depends on
its position, which a highlighter can't fully know without running the program:

- **`#` is a comment only in command position.** Mid-command it is an ordinary character
  (`puts "x" # y` has no comment). The scanner tracks command position (start of line, and
  after `{`, `[`, `;`) and only starts a comment there.
- **Braces `{ … }` are grouping, not a string.** Their body is usually *code* (a proc body,
  an `if` script), so braces are left as plain punctuation and the scanner keeps tokenising
  inside them — a proc body highlights like any other code (verified by running the module
  over rio's own 3000-line GUI and core). This is the opposite call from a here-string
  language, and it's the reason Tcl looks right where a naive "braces = string" would ruin it.

Command position also disciplines the keyword set: core Tcl/Tk command words colour as
`keyword` **only in command position**, so `set list 5` leaves the *variable* `list` plain
(the alternative — colour every known word everywhere — mis-paints argument names constantly).
`else`/`elseif` are the exception (always coloured — they read as `if` arguments, never
variables). It also colours `$var`/`${v}`/`$arr(i)`/`$ns::v` as `variable`, `"…"` strings
(multi-line) as `string`, numbers, a `proc` NAME as `function`, and `-option` flags (dash at a
token boundary) as `attribute`. `[ … ]` re-enters command position, so `[llength $x]` colours
`llength`. Non-command barewords (proc calls, argument words) stay plain — same "don't guess"
rule. Tests: `syntax/tests/tcl.test` (17 cases) — the command-position discipline (keyword vs
argument `list`, `[…]` re-entry, code inside braces), the `#` gotcha both ways, variables, and
`-flag` vs a bare minus.

**Amendment — shell / Bash ships (landed).** `syntax/shell.tcl` (`.sh .bash .zsh .ksh .ash`),
same contract, no registry/GUI change — and, like Tcl, driven by command position because a
shell bareword is positional too. It colours `#` comments (only at word start, so `$#` and
`foo#bar` are safe), `'…'`/`"…"`/`$'…'` strings and `` `…` `` command substitution as `string`
(multi-line), `$var`/`${…}` and the special parameters (`$1 $@ $# $? $$ $! $* $0`) as
`variable`, a `NAME=` assignment target as `variable`, reserved words (`if`/`then`/`for`/…) and
builtins as `keyword`, any **other** command-position word (the command being run) as
`function`, `-x`/`--long` options as `attribute`, and numbers. The one design choice worth
recording: **`$( … )` / `$(( … ))` are not swallowed** — the `$` is left plain and the body is
scanned as ordinary shell, so the inner command colours too (`out=$(ls -l)` colours `ls` and
`-l`), the same "re-enter command position" idea as Tcl's `[ … ]`. A `for`/`case` loop variable
stays plain (not every command-position keyword implies a command follows — only `then`/`do`/
`else`/`if`/`elif`/`while`/`until` do). Verified over rio's own `rio-dev-deploy.sh` /
`rio-server-deploy.sh`. Tests: `syntax/tests/shell.test` (16 cases) — command vs argument, the
`#`/`$#`/`foo#bar` guards, assignments, `$( … )` re-entry, quotes (single non-interpolating),
and options.

**Amendment — Markdown ships (landed).** `syntax/markdown.tcl` (`.md .markdown .mkd .mdown`),
same contract. Markdown is prose, not code, so the design inverts the others': recognise the
**line-level construct first** (heading, thematic break, blockquote, list, code fence), then
scan the remainder for **inline spans**. It colours ATX headings (`# …`) as `keyword`;
thematic breaks and code-fence lines as `meta`; blockquote `>` as `comment`; list markers
(`-`/`*`/`+`/`1.`) as `keyword`; inline code `` `…` `` as `string`; `**strong**`/`__strong__`
as `keyword` and `*em*`/`_em_` as `type`; `~~strike~~` as `comment`; `[text](url)` /
`![alt](url)` as `type` (text) + `string` (url); and `<autolinks>` as `string`. Two care
points worth recording: **`_` emphasis is guarded by word boundaries** so `foo_bar_baz`
(snake_case) is left alone — the one place Markdown and code conventions collide; and a
**fenced code block carries state** (the fence char + length) so only a matching, long-enough
fence closes it, with the body left plain (re-highlighting a code block in its own language is
a noted later refinement). Verified over rio's own README/AGENTS/ROADMAP/PITCH/CONTRIBUTING/
INSTALL (incl. the 2000-line AGENTS.md). Tests: `syntax/tests/markdown.test` (17 cases) —
headings/rules/lists/quotes, the inline spans, the snake_case guard, links/images/autolinks,
and multi-line fences (incl. a non-matching inner fence staying body).

**Amendment — PHP ships (landed).** `syntax/php.tcl` (`.php .phtml …`), same contract. PHP is
**embedded**, so it carries an outside/inside state: text outside `<?php … ?>` is HTML/plain
and left un-highlighted (a later refinement could delegate it to `html.tcl`), the `<?php` /
`<?=` / `?>` markers are `meta`, and inside gets full PHP. It colours `//`/`#` line and
`/* … */` block comments, `'…'`/`"…"` strings (multi-line), `$var` (incl. `$this`, `$$v`) as
`variable`, numbers, keywords, `true`/`false`/`null` as `constant`, a `function` NAME and a
called name (`name(`) as `function`, and a class-ish name — after `new`/`class`/`extends`/… (via
the `pend` mechanism) or a namespaced `\Ns\Class` — as `type`. Honest gap: here/nowdoc
(`<<<EOT`) is not tracked (its marker reads plain). Tests: `syntax/tests/php.test` (16 cases) —
the HTML/PHP boundary (outside stays plain, `<?= … ?>` tags meta), functions/classes/constants,
namespaced types, variables/numbers, and all three comment styles + multi-line string/comment.

**Amendment — Python ships (landed).** `syntax/python.tcl` (`.py .pyw .pyi`), same contract —
and a clean one, since Python tokenises far more regularly than Perl/Tcl/shell. It colours `#`
comments; `'…'`/`"…"` and **triple-quoted** `'''…'''`/`"""…"""` strings — with the `r`/`b`/`u`/
`f` prefixes — as `string` (triples carry across lines via a `str3` state holding the delimiter);
numbers (incl. `0o`/`0b`, complex `2j`, `_` separators); keywords; `True`/`False`/`None` as
`constant`; a `def` NAME and a called name (`name(`) as `function`; a `class` NAME as `type`; and
a `@decorator` as `function` — but only at line start, so the mid-line matrix-multiply `a @ b`
is *not* mistaken for one (the same "disambiguate by position" care as elsewhere). f-string
interpolation is not separately coloured (whole string one span) — a noted later refinement.
Tests: `syntax/tests/python.test` (12 cases) — def/class/call, keywords/constants, the prefixed
and triple-quoted strings (multi-line), numbers, and `@decorator` vs `@` matmul.

**Amendment — C ships (landed).** `syntax/c.tcl` (`.c .h`), same contract. It colours `//` and
`/* … */` comments; **preprocessor** directives (`#include`, `#define`, …) as `meta`, with a
`<header.h>` on an include line as `string`; `"…"` strings and `'c'` char literals as `string`;
numbers (with `0x`/`0b` and int/float suffixes like `UL`/`f`); and it makes the C-idiomatic
**type/keyword split** — control/storage words (`if`/`return`/`struct`/`typedef`/…) are
`keyword`, but the built-in *type names* (`int`/`char`/`void`/…) and any `…_t` identifier are
`type`, so a declaration reads with its types tinted distinctly from its control flow. `NULL`/
`true`/`false` are `constant`; a called/defined `name(` is `function`; a `struct`/`union`/`enum`
tag is `type` (via `pend`). Tests: `syntax/tests/c.test` (13 cases) — the two preprocessor forms
(with the include header), types vs keywords, `struct` tags, `…_t`, strings/chars, suffixed
numbers, and multi-line block comments.

**Amendment — C# ships (landed).** `syntax/csharp.tcl` (`.cs .csx`; registered under the display
name `C#`), same contract. Like C it makes the type/keyword split (control/modifier words as
`keyword`, built-in type names as `type`, `true`/`false`/`null` as `constant`, `name(` as
`function`, a `class`/`struct`/`interface`/`enum`/`new` NAME as `type`). Its interesting part is
**strings in all of C#'s forms**, routed through one `_string` helper: regular `"…"` (with `\`
escapes), interpolated `$"…"`, verbatim `@"…"` — which spans lines (a `vstr` state) and treats
`""` (not `\"`) as the escaped quote — and interpolated-verbatim `$@"…"`; plus `'c'` chars. `///`
doc comments fall out of the `//` rule for free. Honest gaps: `$"…"` interpolation holes aren't
separately coloured, and C# 11 raw strings (`"""…"""`) aren't tracked. Tests:
`syntax/tests/csharp.test` (13 cases) — class/method/new-type, built-in types + null, all three
string forms incl. verbatim's non-escaping backslash and a multi-line verbatim carry, chars/
numbers, and comments.

**Amendment — C++, Go, Rust, JSON ship (landed).** Four more on the same contract, no registry
or GUI change. `syntax/cpp.tcl` (`.cpp .cxx .cc .hpp .hxx .hh .cppm .ixx` — deliberately *not*
`.h`, which stays C, the extension being genuinely ambiguous) is C's highlighter grown up: the
full C++ keyword/type set plus **raw string literals** `R"delim(…)delim"`, which span lines with
their delimiter honoured (a `raw` state carrying the `)delim"` closing token as `param`); `<…>`
template brackets are left plain (less-than/shift ambiguous). `syntax/go.tcl` (`.go`) adds
back-quoted `` `…` `` raw strings (multi-line), the predeclared type names as `type`, `iota`/`nil`
as `constant`, and a `type` NAME via `pend` (function names fall out of `name(`). `syntax/rust.tcl`
(`.rs`) is the richest: `"…"` strings that span lines, raw strings `r"…"`/`r#"…"#` (any hash
count, tracked in `param`), `#[…]`/`#![…]` attributes as `meta`, `macro!` invocations as
`function`, and Rust's strict UpperCamelCase convention exploited to tint any `TypeName` as
`type` — with two ambiguities resolved the D32 way: a `'a` with no closing quote is read as a
LIFETIME (left plain) rather than an unterminated char literal, and `/* */` is treated as
non-nesting (an honest, noted gap — Rust nests them). `syntax/json.tcl` (`.json .jsonc`) tints an
object **key** (a string whose next non-blank char is `:`) as `attribute` and other strings as
`string`, so keys and values read apart; `true`/`false`/`null` as `constant`, numbers per RFC
8259, and — a pragmatic nicety for `.jsonc`/config files — `//` and `/* */` comments. Tests:
`syntax/tests/{cpp,go,rust,json}.test` (46 cases) — raw strings and their multi-line carry,
the char-vs-lifetime split, keys-vs-values, and each language's number forms.

**Where this stands.** Fifteen languages now ship — (X)HTML, CSS, JavaScript, Perl, Tcl, shell,
Markdown, PHP, Python, C, C#, C++, Go, Rust, JSON — all on the one D32 per-line `scan` contract,
with the registry and GUI untouched since the first two amendments (the drop-in loader picks each
up by extension). The recurring design lesson across them: **when a token's meaning is positional
or ambiguous, colour only what's unambiguous and leave the rest plain** — the
`#`-comment/command-position rules (Tcl, shell), the regex/heredoc/raw-string gaps (JS, Perl, C#),
the `@`-decorator vs matmul (Python), the media-query prelude (CSS), the `'a` char-vs-lifetime and
`<…>` template ambiguity (Rust, C++). One shared suite, `syntax/tests/all.tcl`, now runs 237
pure-`tclsh` checks; the GUI applier test loads all fifteen modules.

**Amendment — Lua ships (landed).** `syntax/lua.tcl` (`.lua`), same contract, no registry or GUI
change. Its one distinctive mechanism is **long brackets**, shared by long strings `[[ … ]]` and
long comments `--[[ … ]]`: an opener carries a *level* (the count of `=` between the brackets, so
`[==[`), and only a `]==]` of the matching level closes it — a lower/higher-level `]]` in the body
is literal. A single `long` state carries `{level kind}` across lines, kind being `string` or
`comment`, so both reuse the `_longopen`/`_longclose` pair. Also: `--` line comments; `'…'`/`"…"`
strings; numbers incl. `0x` hex floats with `p` exponents; `true`/`false`/`nil` as `constant`
(not keyword, per Python/Go precedent); the standard-library namespaces (`string`, `table`, `math`,
`io`, `os`, …) as `type` — Lua has no user types, so the predeclared global tables are the nearest
analogue; and a `function` NAME plus any `name(` (incl. `obj:method(`) as `function`. Sixteen
languages now ship; `syntax/tests/lua.test` (13 cases) covers the level-matched long brackets, the
number forms, and the function/constant/builtin rules; the shared suite runs 250 checks.

---

### D33 — Editor split: two side-by-side editor groups, per-group tabs (GUI-only)

Realizes the editor-center split that D13 reserved ("splittable into two editor
groups for side-by-side / diff viewing") and that D28 deferred as the "tabbed
second editor group". A user can show **two editable buffers side by side**, each
its own tab strip — not the read-only compare overlay (D28), but ordinary tabs
opened next to each other, VSCode-style.

**The whole feature is frontend-local — the core does not change.** Per D22, "which
buffer is active" is a frontend concept; the core already holds N independent
buffers addressed by id, with no opinion about how many the frontend displays at
once. So a split is a pure view concern (D3): edits, saves, highlighting inputs and
`buffer.changed` events all keep flowing over the existing protocol by buffer id.
No op, no core file, no plugin is touched — the same reason the file pane and
compare view stayed GUI-side.

**The mechanism — an editor *group* replaces the single-editor singleton.** The GUI
today hard-codes one editor: one text widget (`::rio_real_t`/`.ed.t`), one active
buffer (`::cur`), one highlight line-cache. These collapse into a **group** record
`{widget, cur, hlcache}`; the GUI holds a list of **at most two** groups plus a
`::focused_group`. Editor procs (`activate`, `load_buffer`, cursor/yview stash,
save, modified, the `hl_*` cache, and the `buffer.changed` redraw) take a group and
default to the focused one. This *removes* the three globals rather than adding a
parallel `.ed2` — the anti-bloat discipline: generalize the singleton, don't
duplicate it. The center becomes a `panedwindow` holding one or two groups;
`place_dock` (which already swaps `.ed`↔`.cmp` for D28) grows the second seam.
**Per-group tab strips** (chosen over a shared bar): a tab lives in exactly one
group, so ownership is always visible; a **Move to other side** action shifts it.
New View-menu verbs: **Split editor**, **Unsplit**. Focus follows a click into a
group; the status bar and title read the focused group. `buffer.changed` routes to
whichever group shows the changed id (an agent edit can land in a background group);
the redraw loops over groups, so it already generalizes if a buffer is ever shown in
two at once.

**Scope — v1 is exactly two groups**, matching D13's "two editor groups" (not
N-way tiling). A **buffer belongs to exactly one group** at a time (per-buffer view
state — cursor/viewport — stays keyed by buffer, not by group·buffer); showing the
*same* file in both groups is deferred with the per-group view-state it would need.
Split layout is **not persisted** across restarts in v1 (each launch opens a single
group) — one less D31 prefs-schema change; sticky layout can come later if wanted.

**Landed in two steps.** Phase 2 is a **behaviour-preserving refactor**: it introduces
the group abstraction (`::grp` records: `w`, `path`, `frame`, `tabs`, `cur`, `order`,
the per-group `hl_*` cache), a `make_editor_group` factory that builds each group's
widget + scrollbars + edit-proxy + key/focus bindings, and routes every editor proc
(`activate`, `load_buffer`, `apply_change`, the `hl_*` pass, wrap, theme,
buffer.changed) through a group id — while instantiating a **single** group so the
behaviour is byte-identical and all suites pass unchanged. `::cur` survives as a
mirror of the focused group's active buffer (keeping the focused-only call sites —
save/undo/status/proxy — terse).

Phase 3 makes it visible. The center is a **`.groups` panedwindow** (horizontal, a
draggable sash between the two panes); each group's **tab strip is gridded inside its
own frame** (`.eg<g>.tabs`) rather than a single global bar, so a tab's group is where
it lives. The focused group's active tab is tinted with the **accent** role, so which
pane has focus reads at a glance. Actions (View menu + keys): **Split Editor**
(`Ctrl+\`) opens a second group with a fresh scratch and focuses it; **Move Tab to
Other Group** (`Ctrl+]`) peels the focused buffer across, creating the split if needed;
**Unsplit** folds the second group's tabs back into the first. A group that empties —
via close or move — **collapses** into the other (the sole group instead keeps a
scratch), and a reconnect (`reset_session_state`) collapses back to one group before
adopting the new core. Group ids are the free slot in `{0,1}`, so a collapsed slot is
reused on the next split. New headless suite `rio-gui/tests/split.tcl` covers
open-in-both, per-group highlight, independent editing, focus switch, move/peel,
close-to-collapse, and unsplit; the pre-existing suites still pass unchanged.

*(Amendment — tab context menu.)* Right-clicking a tab handle opens a context menu of
actions **scoped to that tab** (the UI-design bar: a tab's menu holds nothing about
other tabs — "Close Other Tabs" was rejected on those grounds): the split action
(**Split with This Tab** when unsplit, **Move to Other Group** once split — the same
move either way), **Copy Path** (disabled for an untitled buffer), and **Close**. The
move is generalised to a *specific* tab: `move_buffer_to_other {id src}` (which
`move_tab_other` now calls for the focused active tab) moves any tab — active or
background — out of its group, so a non-active tab needn't be activated first, and the
source keeps its own active tab unless the moved one *was* it. `split.tcl` gains the
specific-non-active-tab move plus menu-construction / copy-path checks.

*(Follow-on — one label, not two.)* The context-sensitive wording above was dropped: the
menu item is always **Move to Other Group**. With a single group open the move creates
the other group, so the one label still describes what happens — and it spares the user
a state-dependent relabel of the same control (the simpler, more honest reading of the
UI-design bar). `split.tcl`'s one-group case now also asserts "Move to Other Group".

*(Follow-on — drag a tab across, gesture #2 onto the same move path.)* Moving a tab
between groups now also works by **dragging it**: press a tab, drag it over the other
group's pane, release to drop. It is a second input gesture layered onto the existing,
already-tested `move_buffer_to_other` — the menu item and the drag resolve to the same
core-frozen operation, so the drop path adds no new move logic. Implementation is
**pure Tk, no `tkdnd`** (limited-dependencies bar): press/motion/release bindings on the
tab handle, a ~5px threshold below which it stays a plain activating click, and Tk's
implicit pointer grab keeping motion/release flowing to the origin tab so
`winfo containing` sees across both panes on release. A small `group_of_widget` walks
from the widget under the pointer up to its `.eg<g>` frame (screen-coordinate lookup
split out as `group_at` so the resolver is unit-tested without pointer geometry —
`split.tcl`); feedback is a hand cursor plus an accent tint on the target strip. DnD
clears the UI-design bar on its own terms: drag-a-tab is native to both the Win98/2000
and the VS Code eras, and more discoverable than the menu. The first cut scoped this to
cross-group drops only — see the reorder follow-on directly below.

*(Follow-on — same gesture reorders within a group.)* The drop resolver now branches on
where the tab lands: on the **other** group's pane it moves across (as above); back on
its **own** pane it **reorders**, sliding into the slot under the pointer. The insertion
index is simply "how many *other* tabs have their centre left of the drop-x" —
drop-where-the-cursor-is. As with the move path, the geometry-free part is split out and
unit-tested (`tab_reorder`: order + centres + x → new order; `split.tcl`), while
`reorder_tab` reads the live tab centres and applies. Order is a pure *view* concern
(the core neither knows nor cares about tab order — D22), so a reorder only re-splices
`gorder` and repaints the strip; the active buffer and its text never move. This retires
the deferral and the ROADMAP "Tab reordering" item.

*(Follow-on — held-tab feedback + a 50/50 first split.)* Two rough edges the reorder
gesture exposed. (a) An in-group drag had no visible held state (the target-strip tint
only lights on a *cross*-group drag), so the dragged tab now gets a pressed, accent-tinted
look for the duration of the drag (`mark_dragged`; the drag-end `refresh_tabs` repaints it
away). (b) A freshly created split opened with a sliver second pane — Tk sizes the new
pane from its requested width. `even_split` now centres the sash, but *only* where a split
is **created** (`add_group`, after idle so the pane has a width): moving tabs between two
existing panes never re-lays-out, so once the user drags the sash their layout is kept. Both
are view-only polish — no core, no protocol.

**Deferred (noted):** folding the D28 compare view into this mechanism — once real
groups exist, "compare" could become *open the proposed text as a read-only buffer
in the other group*, retiring bespoke `.cmp` code. Left out of v1 to keep the change
focused; it is the direction that reduces total code, not adds to it.

**Why:** delivers a long-reserved, genuinely useful capability entirely on the
existing seam — core frozen, GUI doing what a view is meant to do — and pays down
the single-editor assumption by turning it into a small explicit abstraction that
the eventual compare-view consolidation can reuse.

---

### D34 — The agent's system prompt: a core-owned, provider-agnostic "soul"

Until now rio sent the model no system prompt (`No system prompt is forced`, the
old claude-api note): the agent had rio's *tool descriptions* but no statement of
how it should behave — how to use the propose→approve gate, or how to write code
well. That is worth having, but it raised a real question of *placement*, because
the obvious wrong answer is to bake one person's workflow into rio's shipped
behaviour. The resolution is a **three-layer split**, and the load-bearing idea is
that the three layers must not mix:

1. **The rio agent contract** — how to act *in rio*: read freely, never write
   directly, propose an edit the user approves/rejects as a diff, match the file
   you're editing. This is not "personality," it's the harness telling the model
   the rules of *this* environment; some of it already lived implicitly in the tool
   descriptions (agent-tools.tcl).
2. **Coding craft** — smallest change that works, don't invent APIs you haven't
   read, prefer clarity, ask when genuinely ambiguous, say what changed briefly.
   Portable across models; tasteful defaults.
3. **User / project specifics** — a given codebase's conventions and don'ts, and a
   user's own habits. This is exactly what must **not** ship in rio.

**Placement follows rio's existing idiom: plain data files, never executed, small
enough to read, overridable under `$XDG_CONFIG_HOME/rio/` — the same treatment as
themes (D24) and highlighters (D32).** Layers 1+2 ship as `agent/prompt.md`
(model-neutral markdown, loaded not run); drop a replacement at
`$XDG_CONFIG_HOME/rio/agent/prompt.md` to override it wholesale. Layer 3 is an
opt-in `.rio/agent.md` at the open project root — instructions that live *with the
project*, not with rio, so a user's Perl-purist workflow (or any house style) is
added without ever touching the shipped code. `rio::agent::prompt::compose`
(rio-core/agent-prompt.tcl) reads base-then-project and joins them with a blank
line; either layer may be absent, and with neither the prompt is empty and the
provider sends none — a safe degrade to the pre-D34 behaviour.

**The soul is a CORE concern, not a provider's.** The same instructions should
shape a turn whether the provider is Claude, the echo stub, or a future local
model, so the **loop composes the prompt once and pushes it to the provider** as a
new fourth argument in the provider contract —
`{*}$provider conversation tools system post`. This is the *same pattern the
contract already uses for `tools`*: the loop hands the provider a capability and a
provider that has no slot for it (echo) ignores it. The claude-api face merges
`system` into a **local copy** of its config-as-data (D26) so the persistent config
stays clean, and the shared inference core already skips an empty `system`. No new
op, no wire change — the prompt never crosses the channel; it is composed core-side
where the agent loop runs (so over a remote core it is the *core's* files —
`agent/prompt.md`, the remote project's `.rio/agent.md` — that shape the turn,
consistent with D30's "the agent lives in the core").

**Why:** it gives rio a genuinely better default agent without a redesign, on a
seam that already existed (the unused `system` field in inference.tcl), while
answering the placement worry structurally — the three-layer split *is* the
mechanism that keeps personal style out of rio's binary. New suite
`rio-core/tests/agent-prompt.test` (7 cases) covers base load, override precedence,
project append, each-layer-optional, and the empty degrade; the claude-api tests
gained the fourth contract arg.

**Deferred (noted):** a provider *may* later append a short model-specific coda to
the shared base (the seam allows it — the face already builds a local config), but
nothing needs one yet. Surfacing the base prompt in the GUI (a Settings view of the
active instructions, editable like the keybindings editor D23) and a per-project
`.rio/agent.md` scaffold are frontend polish left for later. None are on the
critical path — the data files are readable and editable by hand today.

---

### D35 — Tool windows vs. documents: a dock-site system, not chat-as-buffer (direction)

A tempting simplification came up: make the agent chat **just another tab** in the
rightmost editor group, so the user places it with the very same drag/split/reorder
machinery as a text tab — and let *future* extension panels (a git log, a search
result list, a REPL) ride that same universal seam instead of each getting a bespoke
pane. The instinct is right; the literal form is wrong, for two structural reasons and
one *north-star* reason. This entry records the decision so the extension surface has
a decided shape to land on. **Nothing is built here — this fixes the direction.**

**Why not "chat is a buffer."** *Buffer* is a precise **core** concept (D3): a
core-owned text document with a path, encoding, EOL, and undo/redo, broadcast to
frontends via `buffer.changed`. The chat pane is a GUI-only composite (log, input,
approve/reject bar, status, header — `.chat.*`, rio-gui.tcl) wired to a *different*
core subsystem, the agent loop (D20); it has no path, no encoding, nothing to save, no
undo. Calling it a buffer forces one of two bad outcomes: special-case a fake buffer
through `close_buffer`, save, `activate`, highlighting and the core's buffer registry;
or teach the **core** about a non-file "chat buffer," dragging a GUI/agent concept into
the clean file model. Both are worse than the current separation.

**Why not fold tool panels into the editor-group tab strip.** A group today *is a
single text widget*: the D33 machinery (`gw` "the group's real widget," the widget
proxy, the per-group highlight cache, cursor/viewport stash-restore — rio-gui.tcl §D33)
assumes one editor per tab. Hosting heterogeneous view types would generalize the most
delicate part of the GUI. So the honest restatement of the proposal is *"turn the
editor group into a generic tabbed-panel container, of which the text editor is one
view type"* — legitimate (it is roughly how VSCode hosts webview panels in editor
groups), but a real refactor, not a rename.

**The north-star reason (the load-bearing one).** Classic Win2000 / VS6-era
productivity software drew a **hard line between documents and tool windows**:
documents lived in the center with their tabs; tool windows (Output, Properties, Class
View) were *docked* panes with their **own** tabs, and you did not drag them into the
document strip. That separation *was* the clarity. Collapsing everything into one tab
strip is the **modern / VSCode** instinct — pleasant, but it is the half of rio's
"sweet spot" that leans away from the 90s discipline, not toward it. Given the choice,
the more faithful answer keeps the two categories distinct.

**Decision — two clean categories, unify only the tools.** *Documents* stay in the
center editor groups exactly as D33 leaves them. *Tool windows* — the chat today; a git
log, search results, a REPL, and third-party extension panels tomorrow — become
first-class, hosted by a **dock-site system**: a small fixed set of sites (left / right
/ bottom), each a tabbed container the user can move panels between. This is the Visual
Studio docking model: it gives user-controlled placement *and* a single universal
embedding seam for extensions, **without** overloading `buffer` or touching the
editor-group invariants. rio already leans this way — a dockable files+git side panel
and a toggleable right-hand chat column — so this promotes "tool pane" from two
hand-built cases to one declared concept. It is also the natural render target for the
declarative UI contributions of D17/D18: a plugin contributes a *panel into a dock
site*, not a widget into the document area.

**Why now, and why only on paper.** D33 (the split editor) is recent and intricate, and
the plugin/extension interface is *explicitly still being shaped* (ROADMAP → "Plugin
interface — design"), so building this now would be premature and would churn the most
delicate GUI code before its consumers exist. The value today is the **decided shape**:
the chat pane stays exactly as it is (a dedicated pane, D14), and when the extension
surface is built it lands as a dock site rather than as pseudo-document tabs. Recorded
as a *direction*; see ROADMAP for the build item.

**Refinement — the build shape (design pass, not yet built).** The direction above is
settled; this fixes the *concrete seams* the build lands on, so the refactor is
incremental rather than a big-bang rewrite of the most delicate GUI code. Six decisions:

1. **v1 scope: core-team panels only; the plugin UI-contribution seam is deferred.** The
   dock-site host is built for the panes rio *already ships* — files, git, chat, and the
   find-in-files results strip (D51). A *plugin* contributing a panel waits on the
   still-unsettled plugin interface (ROADMAP → "Plugin interface — design"), so it is out
   of v1. This unblocks D35 from the plugin timeline; the panel contract below is shaped
   so a plugin-contributed panel is a later *caller* of it, not a redesign. (Consumers now
   exist — four real tool panes — which is what "why now" was waiting on.)

2. **Three sites, mapped onto what exists.** `left` / `right` / `bottom`. Today's dock
   (files+git, `place_dock` / `::dock_side`) and the chat column (`.chat`, `::chat_shown`)
   become **side-site** tenants; the results strip (`.results`, `-side bottom`) is the
   first **bottom-site** tenant. `::dock_side` (left|right) generalises to "which side a
   panel prefers." The editor groups (`.groups`, D33) are emphatically **not** a site —
   documents stay their own region; keeping the two categories apart *is* D35.

3. **The panel contract is a small data registry — the modes/themes/`rl_*` idiom, not a
   bespoke widget tree.** A tool panel is *declared as data* — `{id, title, site, build,
   refresh, …}` — the same registration shape highlighters (D32), editing modes (D38), and
   the rich-list (D42) already use. The **host** owns the chrome (the tab, the header, the
   close/refresh affordances, the theme hooks); a panel supplies only its *body widget* and
   a *refresh hook*. Files, git, chat, and results become the first four registered panels.

4. **One persisted `layout` object replaces the ad-hoc flags.** Today the layout is flat
   booleans — `dock_side`, `dock_pane`, `chat_shown` (plus `compare_shown`, which is not a
   panel — see below). D35 needs per-site state: each site's visibility, its size, the
   *ordered* list of panels docked there, and which is active. Persist one `layout` dict and
   **migrate** the old keys into it (`dock_side` → the side its panels sit on, `dock_pane` →
   that side's active panel, `chat_shown` → the chat panel's presence/visibility). Settle the
   schema before building; it is the part that is painful to retrofit.

5. **What stays OUT of the site system: the find bar and the compare view.** The find bar
   (`.find`, D36) is an *inline overlay bound to the focused document*, not a tool window —
   it stays special. The compare view (`.cmp`, D28) is a *document-area swap*, not a tool
   panel — it stays too. Only genuine tool windows become tenants, so the abstraction does
   not over-reach into things that aren't panels.

6. **Headless-testability is a design constraint, not an afterthought.** The layout must be
   **queryable as state** — "panel *X* is docked in site *Y* at tab *N*, visible" — so smoke
   asserts placement without a mapped window (the withdrawn-window wall we keep hitting:
   the gutter D49, the results panel D51). The layout manager owns that model; the actual
   `pack`/`grid` is *derived* from it, never the source of truth.

**Incremental path (each step ships green on its own).** (a) Extract the panel component +
registry and migrate the four existing panes onto it — *no* behaviour change, fully
testable; (b) unify all non-document placement (`place_dock`, `show_pane`, the self-packing
bottom strips) into one layout manager reading the `layout` state; (c) introduce the sites,
their tab strips, and move-a-panel-between-sites, driven by that state. D35 is "done" when a
user can drag, say, the git panel to the bottom. Step (a) is the recommended opening move.

**Step (a) — built.** The tool-panel registry landed (`rio::panel::*` in rio-gui.tcl): the
four panes — **files**, **git**, **chat** (`Agent`), **search** — are *declared as data*
(`{title, site, body, refresh}`) exactly like the core's highlighter/mode/rich-list
registries, with `register` / `ids` / `exists` / `get` / `field` / `refresh` accessors. Each
records its **preferred** site (files/git `left`, chat `right`, search `bottom` — the eventual
D35 sites) as static defaults; the *actual, user-movable* placement is deliberately **not**
modelled yet — that becomes step (b)'s persisted `layout` object (decision #4), the
painful-to-retrofit schema, kept out of this slice. **No behaviour change:** `refresh_dock`
and `show_pane` now route their repaint through `rio::panel::refresh $id` (one dispatch),
`on_fs_changed`'s guarded fan-out is untouched, and placement still lives in `place_dock` /
`show_pane` / `search_open`. The registry is the queryable-state seed (decision #6): smoke
asserts a panel's identity/site/hook without a mapped window (19 checks). Steps (b) the layout
manager and (c) the sites/tab-strips/drag remain later arcs (each its own branch), where the
Search panel finally re-homes into the bottom site (D52) and the `layout` schema is settled.

**Step (b) — built (the `layout` object + one derivation).** The persisted `layout` schema
(decision #4) is settled and live: one dict, three sites, each `{panels, hidden, active,
visible, size}` — an *ordered* membership list, the subset with no tab (`hidden`, added for
per-pane show/hide — see D35 below), the foreground pane, derived site visibility, and size
(width for the side sites, height for the bottom). It is the **single source of truth** for all
non-document placement; **`apply_layout` derives the pack from it** (decision #6 — state
authoritative, pack derived), replacing the old `place_dock`/`show_pane`/search packing as
the one choke point. The four call sites became state mutations + `apply_layout`: `show_pane`
sets a site's `active`; `apply_chat_visibility` sets the right site's `visible`;
`search_open`/`search_close` toggle the bottom site's `visible`; `dock_set_side` moves the
files/git panels between the left/right sites. `rio::layout::{default,get,put,site_of,
dockside,migrate,normalize,json}` are the accessors — note the setter is **`put`, not `set`**
(a namespaced `set` would shadow the builtin for unqualified calls *inside* the namespace).
The old flat globals **remain as read mirrors** (`::dock_side`/`::dock_pane`/`::chat_shown`/
`::search_shown`) — `apply_layout` syncs them each pass — because the View-menu radio/
checkbuttons bind them as `-variable` and `on_fs_changed`/`style_selector` read them; they
are no longer persisted or authoritative. **Three settled decisions:** *(1a)* the rare
`dock_side=right` config **unifies** the dock into the right site alongside chat (one site per
edge — the model has three sites, not two strips per edge); *(2)* the Search (bottom) strip
**boots hidden** regardless of what was persisted (an on-demand surface); *(3)* **clean cut** —
after migration only `layout` is written; the old `dock_side`/`dock_pane`/`chat_shown` keys
are dropped (a rollback resets to defaults, unsupported mid-dev). **Newly persisted:** the
dock and chat **sizes** (were ephemeral, reset every launch; now stored per-site on sash
release). `prefs_load` adopts a persisted `layout` or `migrate`s the old flat keys forward,
then `normalize` repairs either into a well-formed layout (fills missing keys, returns any
unclaimed panel to its registry-preferred site, keeps `active` a real member, forces bottom
hidden). Encoded as a nested JSON object (composed via the wire helpers; `json2dict` reads it
back). No visible change in the default arrangement (dock left, chat right, search on demand);
smoke asserts migration, normalize repair, JSON round-trip, and live search/chat/size
derivation without a mapped window (27 checks). Step (c) — the site tab strips and
move-a-panel-between-sites — is the remaining arc, where the Search panel visibly
re-homes into the bottom site (D52) and heterogeneous panels in one site render as one tab
strip. **Relocation gesture (settled with jka): menu first, then drag** — c2 ships a
right-click tab "Move to ▸ Left/Right/Bottom", c3 adds drag-and-drop.

**Step (c1) — built (site containers + host tab strips).** Split to isolate risk. **c1a**
(no-op refactor): the files/git bodies were trapped under `.dock`, but Tk's `pack -in`
requires the master be the slave's parent or a descendant of it, so a panel can only move
between sites if its body shares a common ancestor with every site container. Renamed
`.dock.files`→`.pfiles` and `.dock.git`→`.pgit` (now children of `.`, joining `.chat`/
`.results` there) and shown via `pack -in` — no behaviour change. **c1b** (the visible
slice): three site frames `.site{left,right,bottom}`, each a host tab strip (`.tabs`) over a
body (`.body`); `apply_layout` renders every visible site from `::layout` — `render_tabs`
draws one tab per docked panel (active highlighted), `render_site_body` packs the active
body into `.body` via `-in` (raised — a non-parent-master slave is otherwise obscured), then
the site claims its edge (**bottom first** so it spans full width and the side docks stop
above it, the old Search-strip behaviour). A tab click (`site_tab_click`) sets the site's
`active` and re-derives. **Chrome decision (jka): uniform** — *every* visible site shows its
tab strip, single-panel ones too (chat gets an `[Agent]` tab, search a `[Search]` tab), the
Visual-Studio docked-tool-window look. This retired the bespoke Files/Git selector (now just
the left site's strip) and `style_selector` (→ `render_tabs`/`restyle_tabs`); the sashes
generalised (`.sash`=left site, `.csash`=right, no more `dock_side` math, each persisting its
site's size on release); `show_pane` is a thin alias for a dock-site tab click; `::dock_pane`
is pinned to files|git even when a shared site's active tab is another panel. Structurally
verified headless (smoke 332: uniform strips, tab activation, and search+git rendering as one
strip; the dock/chat/search suites now run through the site model) — but the **visual result
is not headless-verifiable** and wants a live look.

**Step (c2) — built (relocation via "Move to").** Every tab now takes a right-click →
**Move to ▸ Left / Right / Bottom** (the current site greyed out): `panel_move {id target}`
pulls the panel from its site, appends it to the target as that site's active tab, shows the
target, and repairs the vacated site. This is what makes the sites *rearrangeable* and
resolves the asymmetry c1 left: the "Dock Left/Right" menu item only ever moved the files/git
*pair*, so chat was stuck on the right; `panel_move` moves **any** panel to **any** site — the
Agent can now join the left dock beside Files/Git, git can go to the bottom beside Search,
etc. A key refactor rode along: the "Search boots hidden" policy (decision 2) moved out of
`normalize` into a new `boot` (used only at `prefs_load`), so a runtime move *to* the bottom
stays visible while a persisted-open Search still boots hidden. Smoke covers the move, the
chat-to-left symmetry, and no-op guards.

**Step (c3) — built (drag a tab to relocate).** The D35 "done" gesture: drag a tab and drop
it on another site. The tab bindings became a press/motion/release state machine —
`tab_press` records the candidate without activating; `tab_motion` arms a real drag once the
pointer passes a 6px threshold (below it, a plain click) and previews the drop target (the
hovered site, lit with the `accent`); `tab_release` relocates to the site under the pointer
via `panel_move`, or activates the tab if it was only a click, or snaps back on a self/invalid
drop. `site_under_pointer` resolves the drop site from `winfo containing`, mapping a panel
*body* (a toplevel child packed `-in` a site, so its path is `.pfiles`/`.chat`/`.results`, not
under `.site$s`) back through its panel to the site it sits in. Smoke drives the state machine
directly (click-vs-drag, arm, relocate, snap-back) — but the **drag feel is not
headless-verifiable** (`winfo containing` needs mapped windows) and wants a live try. **D35 is
complete** — a user can drag the git panel to the bottom, and every tool panel follows one
uniform chrome rule.

**The settled chrome rule (a fold was tried and rejected; then split by control weight).**
A panel's **controls live in its own body**, never in the tab strip; the **tab strip is tabs
only** (identity + switch + drag/move). A "search-fold" experiment moved *only* Search's query
row out of its body and into the site tab strip; on a live look jka rejected it: the query
controls **mixed visually with the tabs** ("is Git part of the search tools?"), **competed for
width** with the tabs in a narrow window, and made Search the **lone exception** (Files/Git keep
their ⟳ in the body; the Agent composer is a multi-line box that *cannot* sit in a one-line strip
at all). That last point is decisive: since the composer can't fold, "controls in the body" is
the **only** rule that can be uniform — the strip stays tabs-only, each panel owns its chrome.

*Where in the body* then splits **by control weight** (jka's refinement), not by pane:
- **Browse panes — top caption.** Files/Git carry a *thin* header: a name/context line plus a
  tiny glyph button. `.pfiles.hdr` = `[dirname ┄ ⟳]`, `.pgit.hdr` = `[branch ┄ ⟳]`. A one-glyph
  caption belongs at the top, list beneath.
- **Compose panes — bottom controls.** Chat/Search carry a *heavy* control area: a real input
  field + full buttons/checkboxes. That's an input, not a caption, so it hugs the **bottom** and
  the content accumulates above — the type-here/output-above idiom (chat, terminals, REPLs), and
  the input lands in the same place when switching between the two. `.chat` = log fills, composer
  at bottom; `.results` = results well fills, the query row (`[needle · scope · options ┄ ×]`)
  pinned to the bottom, and Ctrl+H toggles the replace row in *above* it (later `-side bottom`
  slave stacks higher) so the query field never moves.

*(Parked idea, ROADMAP: a future per-panel `controls: top | bottom` override, should anyone want
to flip an individual pane against its weight-class default.)*

**Recovery (fixed in c3, from live review).** Dragging a panel into the bottom exposed a
stranding bug: `boot` force-hid the *whole* bottom site to keep Search on-demand, so a Git
dragged there vanished on the next launch with no way back. Two fixes: (1) `boot` now hides
the bottom **only when Search is its sole tenant** — once other panels are docked there it
honours the persisted visibility; (2) `show_pane` became **`panel_reveal`** — it reveals a
panel *wherever it lives* (makes its site visible + the panel active), so the reveal keys
(`Ctrl+E`/`Ctrl+G`) and the View menu always recover a pane, none can become unreachable.
General principle for the site system: **no arrangement may strand a panel with no menu path
back.**

**Per-pane show/hide — a tab-presence model (live-review, two rounds).** The View-menu pane
items are **checkbuttons** (`Files / Git / Agent / Search`); each toggles whether that pane is
*shown*, where **shown means it has a tab at all** — *not* merely which tab is foreground. This
needed a schema change: each site now carries a **`hidden`** list (members present but with no
tab) beside `panels` (membership); `visible` became **derived** — a dock is on screen iff it has
a non-hidden pane. `rio::layout::shown id` = "id has a tab" (`id ∉ hidden`), mirrored into
`::shown_*`. `panel_toggle` adds/removes a tab: hiding the foreground pane hands the foreground to
another shown sibling; **hiding a site's last shown pane collapses the whole dock** — so any pane
can be *fully* hidden, exactly as the solo Search pane always could (the earlier "toggle switches
foreground" attempt couldn't hide a pane sharing a dock, which read as broken). The reveal *keys*
(`Ctrl+E`/`Ctrl+G`) stay idempotent "go-to" (`panel_reveal` = give a tab + foreground); the
Agent's `Ctrl+Shift+A` toggles. `hidden` persists in `layout` JSON; old layouts without it recover
it in `normalize` from the stored `visible` (collapsed dock → all hidden). The standalone *Agent
Chat* checkbutton folded into `Agent`; `apply_chat_visibility` survives (now a hide/unhide of the
chat tab) for the tests that flip `::chat_shown` directly.

**First-run default layout.** A brand-new user (no prefs → `rio::layout::default`, not the
migrate path) sees **only the Files tab, on the left** — Git lives there too but starts *hidden*
(no tab), and the Agent (right) and Search (bottom) start hidden — a clean editor with just the
file tree. Everything past that is the user's own choice and persists (`prefs.json`'s `layout`).
Upgraders keep their old arrangement via `migrate`, which shows a tab for every dock member (git
a background tab, agent per the old `chat_shown`) — the pre-layout behaviour; only the first-run
seed hides git.

**Dock sizes are user-chosen and stable (live-review fix).** A dock's extent is a property of
the *site*, not its content: the side sites were already fixed-width (`pack propagate 0` +
`-width`), and the bottom site now matches with fixed-height (`propagate 0` + `-height`), so
switching between its tabs (a tall git diff vs the short Search strip) never resizes the dock.
The bottom gained its own resize grip — a horizontal `.bsash` (`bsash_drag`) mirroring the
side `.sash`/`.csash` — so the user *chooses* the height, and it persists like the widths.
Only a sash drag changes a dock's size; never its content. (Also: the Search panel's default
scope is now **Current doc**, not Project — the find-bar escalation still deliberately widens
to Project.)

---

### D36 — Find / Replace: the engine in the core, a bar in the GUI

rio had no Find. Not in a menu, not as an op — the Edit menu was Undo/Redo and
nothing else. That put it *below* the 90s baseline the project claims (even
Notepad has Find/F3/Replace/Go-To), and it wasn't even tracked as a gap. This
decision adds in-buffer **Find, Find Next/Previous, Replace, and Replace All**,
and fixes where each half of the feature lives — a placement question worth
recording because the obvious approach (Tk's built-in `$t search` on the GUI's
widget, frontend-only) was proposed first and is **wrong** for rio.

**The engine is a core concern.** The core owns the canonical text (D3);
searching a frontend's *mirror* of it is the dumb-view discipline leaking. The
precedent is `diff.lines` (D28): a pure text computation every frontend needs
runs core-side, once. So matching lives in the document model
(rio-core/document.tcl) and is exposed as three **stateless** ops:

- **`buffer.find {needle, ?from?, ?nocase?, ?backwards?, ?wholeword?}`** → the next
  match at or after `from` (or the nearest one starting before it), **wrapping
  around** the document; returns `{found, start, end, wrapped}`. Statelessness is the
  D22 boundary honoured: *where the caret is* is frontend-local — two frontends
  on one core each have their own — so the caller passes its position in and no
  find state lives in the core. Matching is by character offset over the joined
  text, so a needle may span lines; `nocase` uses Tcl's simple one-to-one case
  mapping, so offsets stay stable.
- **`buffer.matches {needle, ?nocase?, ?wholeword?}`** → `{count, matches:[{start,end}]}`,
  every match first-to-last — the frontend's match count and highlight-all.
  A non-flat result, so the wire layer registers a shape encoder (D25).
- **`buffer.replace_all {needle, text, ?nocase?, ?wholeword?}`** → `{count}`; replaces every
  match as **one recorded edit** — Replace All is one user action, so it is
  one undo step and one `buffer.changed`, not N of each. The replacement
  segments come from the original text, so case outside the matches survives
  `nocase`. Zero matches means no edit and no event. (Single **Replace** needed
  no new op at all: it is a found range plus the existing `buffer.replace`.)

**`wholeword`** (D51) is shared by all three: a hit counts only when neither flank is
a word character (letter/digit/underscore, Unicode letters included). The one boundary
test (`rio::doc::_bounded`, over the joined text so a line break bounds a word for free)
serves find, matches, and replace_all alike — so the bar's count, its step-to-next, and
Replace All all agree, and the same rule is what core-side find-in-files uses. It arrived
first on `project.search` (D51) and was folded back here so the in-buffer bar matches.

Two further reasons the core-side placement is load-bearing: a future TUI or
third-party client (D2/D30: "any language at the far end") gets the same engine
over the protocol instead of reimplementing it against its own view; and
**find-in-files, when it comes, is *necessarily* core-side** (in remote mode
only the core can see the project tree) — the in-buffer ops make project search
an extension, not a second architecture. The latency worry dissolves on
inspection: every keystroke already round-trips one `buffer.replace`, so one
`buffer.find` per Find Next costs what typing costs.

**The GUI grows a find bar, not a modal dialog.** One bar (Find row; a Replace
row that Ctrl+H adds), packed above the status bar, acting on the **focused
group** (D33). A bar over a dialog is the one deliberate departure from
Notepad's modal Find box: it keeps the text visible and the matches painted
*while you type the needle*, and it is the form both eras converged on
(Netscape/IE find bars then, every editor now) — the 90s clarity kept is plain
labelled controls, no icons but the × close (D27). Behaviour: matches are
painted live on every needle keystroke (`buffer.matches`; the paint is capped
at 1000 ranges so a one-letter needle can't stall the view — the count stays
exact); the current match is the native selection with the caret on its far
side; Enter/F3 step forward, Shift-Enter/Shift-F3 back, Esc closes; the count
label reads "12 matches", "3 of 12", "· wrapped", "Replaced 5", "No matches".
**Replace is the classic two-step**: if the selection *is* a match it replaces
and steps, otherwise the first click only selects — a replace is always visible
before it happens. An open bar stays honest against a changing buffer: any
`buffer.changed` (typing, an agent edit, undo) schedules a recount coalesced on
the idle loop, the same pattern as the incremental highlighter (D32), and a tab
switch recounts for the newly focused buffer. All four commands live in the
keymap table (D23) — Ctrl+F, Ctrl+H, F3, Shift+F3, remappable like everything
else — and the Edit menu gains the four entries (later moved to a top-level **Find** menu,
D75). The match paint is a
`findmatch` text tag coloured by a new **`editor.findmatch` role** in the theme
vocabulary (D24): the default is the familiar pale yellow, the three shipped
themes retint it, and any theme that omits it inherits the default; the
selection tag rides above it so the current match reads.

**A bug worth recording, because it bit twice in one feature.** Tk text indices
passed through `expr` decay: the ternary `[expr {$cond ? $idx : "1.0"}]` turns
column 10 into column 1 ("1.10" → the float 1.1). This exact bug is documented
at the editor proxy's delete arm — and both the GUI's find_step *and* the
buffer.find op handler reintroduced it independently before tests caught them.
The op-level regression test (`op-find-from-col-ten`) now pins it. Moral
unchanged since the proxy: never let a line.col index near `expr`.

**Why:** the single most-missed everyday editor feature, delivered on rio's own
seams — the engine beside the document model it queries, the state where D22
says state lives, the edits through the ops that already existed, the colours
through the theme vocabulary, the keys through the keymap table. No new event,
no protocol change beyond three ops. Tests: `rio-core/tests/find.test` (32
cases: offset/position geometry, forward/backward/wrap/nocase/multi-line
matching, replace-all's one-undo-step contract, op validation), two wire-shape
cases in wire.test, and a new headless GUI suite `rio-gui/tests/find.tcl`
(open/close modes, counting and painting, stepping with wrap, match-case, the
two-step replace, replace-all + single undo, live recount after an edit, and
the bar tracking the focused group across a split).

**Deferred (noted):** whole-word and regex options (the bar's options row has
room; the ops grow a flag when wanted); **Find in Files** — core-side by the
same argument that placed the engine there, surfacing as a search-results panel
in a dock site once D35's tool-window mechanism exists; highlighting matches in
the compare panes (same deferral as syntax highlighting there, D32).

### D37 — Stale-link detection at the protocol layer, not the socket layer

The reported failure: a GUI attached to a remote core through an `ssh -L`
tunnel; the tunnel went stale. The socket stayed **half-open** — writes still
succeeded into the kernel buffer, but no replies and no EOF ever arrived — so
clicks silently did nothing, and only 5–10 minutes later did TCP itself give up
and trip the generic "lost the connection" path. The question raised with the
report was the right one: can the GUI notice this *without* new
network/socket/system code?

**Yes — the pieces already existed; they just only ran once.** `hello_core`
bounds the *first* exchange on every fresh channel (8 s) for exactly this
scenario — the comment beside it names the stale forward — but after the
greeting every op waited unbounded. D37 extends the same idea to the whole
session: a small **watchdog** in the GUI (`watch_start`/`watch_stop`/
`watch_tick` beside `core_lost`), built entirely from what was there — the
bounded-call timer `core_call` already had, `session.hello` as a free ping, and
`core_lost` as the one teardown path. No socket options, no TCP keepalive, no
OS-specific anything. Every 10 s it checks, in order:

1. **An overdue reply** — a call pending longer than 25 s. This is a safe
   verdict because no rio op legitimately holds its reply open: streaming ops
   ack immediately and stream as *events* (D26), so even a full agent turn
   never has a reply outstanding for minutes. The threshold is generous on
   purpose — the core is single-threaded and a big reply on a slow tunnel
   counts its transfer time. `core_call` now records *when* each call was sent
   (the `::pending` value was previously an unread `1`).
2. **An idle probe** — nothing pending *and* nothing received for a full
   interval (`core_reader` stamps `::last_rx` on every line; streaming events
   count as life, so a busy turn is never pinged) → one `session.hello` bounded
   at 8 s. Only a `timeout` verdict counts; a write failure already went
   through `core_lost` inside `core_call`.

Either finding funnels into `core_lost` — same teardown as an EOF (pending
calls woken with `disconnected`, editor stays up, nothing in view lost) — but
with a message that says what actually happened and what to do: the link went
stale, re-establish the tunnel, then *File ▸ Connect to Remote Core…* (the last
endpoint is prefilled). Detection lands within ~35 s idle, ~25 s after a click
— versus minutes before.

**Armed only for a socket-attached core** (`::core_remote`, at startup and on
an in-place reconnect). A spawned local core is a *pipe*, and a pipe delivers
EOF the moment the child dies — the half-open pathology is socket-only, and
keeping the watchdog off the local path keeps its false-positive surface at
zero for the common case. **No auto-reconnect**, deliberately: the tunnel has
to come back before a reconnect can succeed, and silently re-attaching to a
daemon is new policy (session adoption, unsaved-buffer questions) that File ▸
Connect already answers with the user in the loop.

**Why:** the protocol layer is rio's own seam — the GUI already round-trips an
op per keystroke, so "is anyone answering?" is a question the channel can
answer by itself, with two timers and an op that already existed. The
thresholds are plain globals so the headless suite can shrink them. Tests:
`rio-gui/tests/stale.tcl` (11th suite) — a pure-Tcl black-hole server (accepts,
reads, never replies) plays the stale tunnel; asserts a live core is never
falsely disconnected across several probe rounds, a blocked call is woken with
`disconnected` and the stale message reported once, subsequent ops fail fast,
and the idle probe detects staleness with no user action at all.

### D38 — Editing modes: a bind-tag layer, loaded like syntax highlighters

Until now the text area's editing feel was **whatever Tk's built-in `Text`
class bindings do** — an accident, not a decision. On X11 that meant a partial
emacs flavour (Ctrl+K kill-line, Ctrl+D delete-char) with Windows-style
navigation, no select-all at all, and one real bug: **Ctrl+V looked like it
broke scrolling** (thumb moved, view stayed at the top). The post-mortem, from
reading Tk's own `tk.tcl`/`text.tcl` and a runtime probe: on X11 `<<Paste>>`
maps `<Control-v>` and the page-scroll binding is **aqua-only**, so Ctrl+V was
silently *pasting* at the caret (line 1.0) — the buffer grew, the thumb moved,
and `apply_change`'s `see insert` pinned the view to the top. Nothing was
wrong with the scroll wiring; the keys were never ours to begin with.

D38 makes the keyboard a decision. rio ships three **editing modes** —
**windows** (the default: Ctrl+A select-all, Ctrl+C/X/V clipboard with
paste-replaces-selection, Ctrl+Backspace/Delete word deletes, Tk's emacs
leftovers deliberately dead), **emacs** (Tk's readline extras kept, plus the
line/char motions X11 Tk lacks — Ctrl+A/E/B/P — and Ctrl+V/Alt+V as real page
scrolling, which *is* the bug fix), and **vi** (modal: normal/insert/visual,
counts, motions `h j k l w b e 0 $ gg G`, operators `d c y` with motion
targets and doubled forms, `x p u i a o O v`; block cursor in normal, a
`-- INSERT --` status segment). Picked in **Settings ▸ Editing Mode**,
persisted as one `prefs.json` key (D31 applier pattern, `apply_editmode`),
default windows — the D-order intuition bar (a Win98/2000 + VSCode user)
decides the out-of-box feel; the other camps are one menu click away.

**The mechanism is one shared bind tag.** `make_editor_group` slots `RioMode`
between the widget path and the `Text` class in every editor's bindtags:

    .eg<g>.t   RioMode   Text   .   all

That one line fixes the precedence *by construction*: app keymap chords (D23,
bound on the widget path with `break`) always beat the mode — save/find/undo
are sacrosanct in every mode, stated in the shortcuts dialog — mode bindings
that `break` beat Tk's Text defaults (a physical chord on an earlier tag
cleanly preempts Text's virtual `<<Paste>>`), and what a mode doesn't bind
falls through to Tk untouched (emacs mode *is* mostly fall-through). A mode
switch detaches the old mode, wipes the tag centrally (a mode can never leak a
binding), and attaches the new one; the tag being shared means every group —
including a split created later — is covered with no per-widget rebinding.

**Modes are the second stable extension surface, on the D32 pattern — not
D17 plugins.** A mode is a self-registering Tcl module
(`modes/<name>.tcl`, `rio::modes::register name label attach detach`), loaded
registry-first, shipped modules then user drop-ins from
`$XDG_CONFIG_HOME/rio/modes/`, later registration wins, a broken module is
skipped and never fatal — `modes_load` is `hl_load` line for line, and the
picker menu is built from the registry so a drop-in appears with no wiring.
*Considered and rejected:* waiting for the D17 plugin API — its D18 shape
(declarative UI, "never raw Tk code") is structurally wrong for per-keystroke
behaviour, and the highlighter loader is proven. Unlike syntax scanners the
mode *modules* are explicitly frontend code (they bind, they call `tk::Text*`
helpers); only the registry is pure Tcl, so a TUI reuses the registry with its
own modules.

Everything is frontend-local (D22): the core never learns which mode is
active. vi's per-group state (a vi "window": normal/insert/visual, pending
operator, count) lives beside the highlight cache (D33); its motions are
computed **exclusively with Tk index arithmetic** — `$w index/compare`, the
`tk::Text*` helpers — never `expr`, which corrupts `line.col` (the D36
lesson, now stated in the module header). Operators call the group *proxy*,
so a `dd` reaches the core as one `buffer.replace` = **one undo step**; the
yank "register" is simply the X clipboard, which makes `dd`+`p` round-trip
(linewise yanks carry a trailing newline as their marker) and lets a vi yank
paste into other applications. The proxy grew a `replace` arm alongside
`insert`/`delete` so paste-over-selection is also a single edit/undo. The
Edit menu gained the Win98-canon Cut/Copy/Paste/Select All, calling the same
shared procs the windows mode binds — menu and keys cannot drift.

Deliberately not in vi v1 (ROADMAP): ex commands, named registers, macros,
`.` repeat, marks, visual-line; emacs v1 has no kill ring. Insert state *is*
Tk's Text editing — only Escape is intercepted — so typing, Backspace and
selection behave identically across modes.

**Why:** the keyboard feel of the text area is exactly the kind of behaviour
D21 wants to be a user *choice*, and the pieces to make it one were all
proven: the bindtags order gives layering for free, the D32 loader gives
extensibility for free, the D31 prefs applier gives persistence for free.
This also closes **O6**: the default scheme is the windows mode, and modal
editing is offered as a first-class mode rather than a fork of the editor.
Tests: `rio-gui/tests/modes.tcl` (registry, loader drop-ins/broken-module,
windows clipboard through the core, emacs motions, the Ctrl-V regression both
ways — emacs C-v scrolls and *never* pastes, windows C-v pastes) and
`rio-gui/tests/vi.tcl` (90 checks: transitions + chrome, counts, motions,
operators, doubled forms, both `p` arities, visual, aborts, clean detach with
an operator pending, per-group state across a split).

*(Amended 2026-07-23 — windows mode block-indent.)* The windows mode bound no
`<Tab>`, so Tk's `<Tab>` (`tk::TextInsert`) **replaced a selection with a tab** —
select some lines, press Tab, they vanish. Fixed on the D38 pattern: two shared
`editor_indent`/`editor_dedent` procs (beside `editor_cut`/etc., so the menu could
share them later), bound to `<Tab>`/`<Shift-Tab>` (+`<ISO_Left_Tab>`, X11's
shifted Tab) in the windows mode. With a selection they shift **every line the
selection touches** by one tab, keeping each line's existing leading tabs/spaces
and pushing them along — done as one `$w replace` through the proxy, so a
multi-line indent is **one core edit = one undo step**, and the block is
re-selected so repeated Tab stacks levels. Rules matching VSCode/Notepad++: a
wholly blank line isn't grown into trailing whitespace; a selection ending at
column 0 doesn't pull in that trailing (untouched) line; Tab with no selection
inserts a plain tab; Shift+Tab with no selection dedents the caret's line. Dedent
strips one leading tab, else up to a 4-space tab stop. Ctrl+Tab / Ctrl+Shift+Tab
(the app's tab-cycle chords, D23) are a different chord and untouched. Tests:
the block-indent group in `rio-gui/tests/modes.tcl`.

### D39 — Extension repositories: apt-sources over plain HTTP; never a marketplace

rio had two stable extension surfaces (syntax D32, editing modes D38) plus
themes (D24) — and no way to *share* one except copying a file by hand. D39 is
the distribution story, realizing D19's stance ("no marketplace platform;
self-hostable; the store is one config entry") in its simplest durable form:
**the apt-sources model over plain HTTP**. The user keeps a `sources.list`
(`$XDG_CONFIG_HOME/rio/sources.list`, one base URL per line, `#` comments —
hand-editable, and edited by the GUI's *Repositories…* dialog); each URL names
a **plain http-served directory**; there is **no central index and no central
authority, by design**. The name is **"Repositories"** — emphatically not
"marketplace": no store, no accounts, no platform to operate, nothing to shut
down. The durability bar was explicit: *works in 20–30 years, like OpenBSD's
plain-http mirrors, even if git disappears* — which is also why **git-backed
sources were dropped from v1** (a Forgejo raw-URL prefix already qualifies as
an http directory, so nothing is lost).

**The formats** (all D21 conf — data, parsed, never executed; the complete
publisher-facing spec lives in CONTRIBUTING.md "Extension repositories"):

- `<base>/rio-repository.conf` — **required marker + manifest** (`name =`
  required; `description =`, `maintainer =` shown). No parseable marker → the
  source is refused as "not a rio repository" — a bare webdir is never
  mistaken for one.
- `<base>/index` — one extension-subdir name per line, `#` comments.
  **Optional**: without it rio parses the server's autoindex listing (one
  tolerant href pass, verified against canned Apache/nginx/OpenBSD-httpd
  output). An explicit index is sturdier (listings off, staged-but-unlisted
  dirs); the fallback keeps "just point it at a directory" honest.
- `<base>/<extdir>/rio-extension.conf` — `name`/`kind`/`version`/`files`
  required, `author`/`description` shown. `version` is an **opaque displayed
  string, never compared** — rio offers what's listed and the user decides;
  no dependency-resolver ambitions. Payload files sit beside the manifest:
  one extension per directory, N files, no subdirs (v1), text only, fetches
  capped at 2 MB.
- **The safe-name rule**: every remote-supplied name (extdir, name, kind,
  each file) must match `^[A-Za-z0-9][A-Za-z0-9._-]*$`, checked before any
  URL or path join — path traversal and percent-encoding die at the format
  level, in one rule, on both sides (GUI scanner and core theme store).

**The forward-compatibility contract**, stated structurally because the user's
requirement was open-endedness ("our extension system should work with later
community-contributed plugins we can't think of yet"): parsers **ignore
unknown keys** in both conf files, and **unknown kinds list but don't
install** — greyed "(needs a newer rio)" — so a future kind (a deploy tool, a
protocol bridge) ships today's format without breaking today's rio. Only the
v1 kind→install-target map is version-specific: `syntax` → the GUI's
`~/.config/rio/syntax/`, `mode` → `~/.config/rio/modes/`, `theme` → the
**core's** user themes dir.

**The split of labour** follows D30's geometry. Fetching runs **core-side**:
new `rio-core/http.tcl` (`rio::http::get` — bounded: ≤5 redirects with
relative-Location resolution, 2 MB cap; a completed exchange incl. 404 is
data, only no-answer is `io_error`) surfaced as the `repo.fetch` op — so a
remote core fetches from *its* network and the GUI grows no network
dependency (INSTALL.md's promise that a GUI-only box needs no tcltls holds).
**Plain `http://` only — rio implements no TLS of its own** (user decision:
operators front a webdir with relayd/nginx if they want https; rio-side TLS
is a ROADMAP deferral; `https://` is a clean `bad_request` with that advice).
Themes install core-side through new ops — `theme.list` / `theme.put`
(validated before written) / `theme.delete` (user dir only; shipped themes
are the installation, not user state) — which also turned the GUI's
**hardcoded four-theme View menu dynamic** (filled from `theme.list`, radio
snapping back on a failed switch). Syntax and modes install **GUI-side** into
the existing drop-in dirs: an install is exactly the hand-drop D32/D38
already honour, performed by rio.

**No central index ⇒ collisions are a feature, honestly handled.** Same-name
extensions from different sources coexist as separate *variants*, each
labelled `version by author — source-host`; the user chooses ("Really good
software just works like that"). Every install is recorded in a **provenance
ledger** (`$XDG_DATA_HOME/rio/extensions.json`: `kind/name` → source, dir,
version, files, date; corrupt → empty, never fatal), which powers the honest
replace consent ("replaces X 1.0 from host"), the flat-dir collision refusal
(a payload filename owned by a *different* installed extension refuses to
install rather than silently overwrite), offline rows (an installed
extension whose source vanished is synthesized from the ledger so Remove
always works), and updates (= installing the newer-listed variant; rio never
auto-updates). Recorded caveat: the ledger is GUI-side — "this GUI installed
X onto its core" — so a second frontend on the same daemon doesn't see it; a
core-side ledger is a ROADMAP item.

**Consent is code-vs-data, with provenance.** Installing syntax/modes says
"Tcl CODE that will run inside your editor" next to the source URL; themes
say "data, never executed". Install is all-or-nothing: every payload is
fetched before anything is written, and a half-failed write rolls back. No
signing, no sandbox in v1 — the trust model is apt's (your sources list is
your trust list), documented honestly in CONTRIBUTING. The
**`.well-known/rio-repository`** hook is specced (host-root plain-text list
of vouched repository paths — the operator confirming "these are mine") but
consumed by no v1 code: it's the later basis for "host-validated" badges and
official approval, costing publishers one static file today.

**The UI is the Extensions window** (*Settings ▸ Extensions…* — under View until
D67) — deliberated as a
side-dock pane vs a window with the user: the dock's narrow fixed-width panes
(files/git) can't carry a browse-and-compare surface, and VSCode's own
answer (detail opens in an editor tab) needs D35 machinery that doesn't exist
yet, so the honest v1 is a **non-modal toplevel** — rio's first D35-style
tool window, to re-host into a dock site when D35 lands. Naming: the window
is "Extensions" (what you browse), the sources are "Repositories" (where
they come from). One row per (kind, name), aggregated; the detail section
lists **every variant** with its own Install/Remove — the choose-between
surface; unknown kinds greyed; one honest `!!` row per dead source.
Non-modal means re-entry is real: `::repo_busy` gates one scan/install at a
time (the sequential `core_call`s pump the event loop, so the editor stays
live). The small *Repositories…* sources editor may be modal — it's a
focused edit, not a browsing surface.

**Why:** distribution had to exist for the extension surfaces to matter, and
every alternative shape — a marketplace service, a curated index, git-clone
plumbing — either creates an operator, a gatekeeper, or a dependency that can
rot. A plain http directory has none: it outlives hosting fashions, any web
server can serve it, a stranger can publish with three text files, and rio's
own honesty rules (provenance shown, code named as code, collisions surfaced
to the user) substitute for the authority a central index would fake. Tests:
`rio-core/tests/http.test` (socket-free: resolution, refusals, validation),
theme.test store additions, and `rio-gui/tests/repos.tcl` (~90 checks:
parsers against canned listings, consent both ways, install/replace/remove
end-to-end for all three kinds through the real registries and core, the
collision refusal, ledger round-trip + corrupt tolerance, and the window —
aggregation, variants, filter, busy guard, offline rows, the sources
editor). Live-network behaviour is verified against a real webdir at release
(no live HTTP in the test environment — the fetch seam is stubbed with
fixture tables instead).

**Addendum (2026-09-09) — ship with the project repo pre-filled.** rio now seeds
`sources.list` with **one default repository, `http://rio.skylm.org/rio`** (the project's own
extension repo), so a fresh install has something to browse in the Extensions window out of
the box instead of an empty list. The seed (`sources_seed_default`, run once at boot after
`ledger_load`) is a **true-first-run-only** act — it writes the file *only when it does not
yet exist*. Removing the repo in *Repositories…* leaves a header-only file behind, so the
file now exists and the default **never comes back**; the seed also can't override a
hand-edited list. Stored **without a trailing slash** (`repo_source_scan` appends
`/rio-repository.conf`). It's just a normal source once seeded — no special status, no
pinning, plain HTTP like any other (still no rio-side TLS, D39). The URL is a single constant
(`::default_repo`); `repos.tcl` covers the seed, its idempotence, and the no-re-seed contract.
The repo is currently a test/POC endpoint that may become the production home.

### D40 — Column / block editing: a vertical multi-line cursor, GUI-only

Notepad++'s **column mode**: a rectangular (vertical) selection whose zero-width
form is a caret spanning many lines — type and the character lands at that column
on **every** line; Backspace/Delete/Tab act per line too; drag a width and typing
overwrites that rectangular slice. rio ships this, **off by default**, a Settings
checkbutton (`::col_on`, persisted with the other prefs).

**Gesture: Ctrl+Shift+drag, deliberately *not* Alt+drag.** Notepad++'s real
gesture is Alt+drag, but on Linux/X11 the window manager almost universally grabs
Alt+drag to move the window, so it never reaches the app. Ctrl+Shift+drag is
clash-free (and is what the requesting user reached for). Bound in the **windows**
mode only — Notepad++ is a windows-style editor, and vi/emacs have their own
block/rectangle notions; the pref gates the binding so it's inert until enabled.

**No core changes — one span-replace is the whole trick.** rio already emits any
multi-point edit as a *single* `buffer.replace` over the affected span with
pre-transformed text; that is how `replace_all` and the D38 block-indent get "one
undo step". A column op is the same shape: read `L1.0..L2.lineend`, apply the
per-line edit (padding short lines with spaces — column mode's virtual space),
rejoin, one `buffer.replace`. So a 40-line column edit is **one undo step, one
`buffer.changed`**, and the core/protocol learn nothing new. Everything lives in
`rio-gui.tcl` `col_*` procs on the group PROXY path; the windows mode binds the
Ctrl+Shift gesture plus `<KeyPress>`/`<BackSpace>`/`<Delete>`/`<Tab>` hooks that
consume the event *only* while a selection is live (`col_here`), else normal
editing flows through. Repaint rides the same post-edit path as wrap-indent (the
`buffer.changed` redraw drops the tags, `col_paint` re-adds).

**Rendering (refined on live review).** A **width** selection is the `coltag` theme
tag — a rectangular band per line, reusing the selection colour. The **zero-width**
caret column is *not* a tag: the first cut drew a solid `colcaret` block per line
(a bold static bar — wrong), so it now draws a **thin blinking bar per spanned
line** (`col_bars_draw` places 2px `frame`s at each line's caret x via `bbox`, one
shared 500 ms blink loop in `col_blink_tick`), matching the normal caret stretched
down the column. To keep the caret line in phase with its siblings the native
insert bar is hidden (`-insertwidth 0`) while the caret column is live and restored
on clear. Bars are placed *after* `see insert` so they land at the final scroll
position; off-screen lines (empty `bbox`) are skipped.

**Windows-only, and the UI says so.** The gesture already only binds in the windows
mode, so it's inert in vi/emacs regardless — but the Settings **Column Editing**
checkbutton was always live, which was misleading. `sync_column_edit_menu` now
greys the entry out (whatever its stored value) unless windows mode is active;
`apply_editmode` calls it on every mode switch, boot calls it once.

**v1 boundaries (ROADMAP).** Columns are *character* columns (a tab inside the
band can look misaligned — pixel/tab-accurate columns deferred). Deliberately out:
rectangular clipboard (Ctrl+C/X/V keep normal behaviour), keyboard-built columns
(Alt/Ctrl+Shift+arrows), and arbitrary multi-caret (Ctrl+click) — the last is a
straight generalisation of the one-span-replace model when wanted. Tests: the
column group in `rio-gui/tests/modes.tcl` (caret-column typing with one-undo,
virtual-space padding, block overwrite, per-line Delete/Backspace/Tab, the
modifier/inactive/pref-off guards, the native-bar-hidden-while-caret-column /
restored-on-clear invariant, and the menu grey-out outside windows mode).

---

### D41 — The core ships one editing mode; emacs and vi become extensions

D38 shipped three editing modes (windows/emacs/vi) as peer files in `modes/`.
Getting each of the non-default modes *really* good — vi's ex commands, registers,
`.` repeat, macros, marks; emacs's kill ring — is open-ended work (the D38/ROADMAP
"editing-mode extensions" cluster). Rather than carry that weight in the core, the
distribution now ships the **Windows mode only**; **emacs and vi move out into
installable extensions** and can iterate on their own cadence, versioned and
replaceable like any other extension.

**This costs no new mechanism — it's the D39 extension system doing exactly what
it was built for.** A mode already installs as a repository `kind = mode` payload
into `~/.config/rio/modes/`, and `modes_load` already loads shipped modules then
user drop-ins that shadow by re-registering (D38). So "unbundle a mode" is just:
move `modes/{vi,emacs}.tcl` out of the shipped tree, and serve them from a
repository. The repo carries them verbatim — a mode module is frontend code that
binds keys on the RioMode tag; nothing about it changed.

**Layout.** The repo tree lives at `extensions/` in the source tree, shaped as a
real, complete rio repository (`rio-repository.conf` + `index` + one dir per
extension with a `rio-extension.conf` manifest and the `.tcl` payload) — rsync it
to a plain-HTTP webdir and it *is* the repository, no build step. It doubles as
the worked reference example for CONTRIBUTING's "Extension repositories" spec.

**A persisted mode that's no longer installed falls back cleanly.** `apply_editmode`
already checks `rio::modes::exists` and drops to `windows` when the saved mode is
absent (D38), so a user who had `vi` selected and hasn't installed the extension
lands in Windows mode, not a broken state — the fallback that used to guard
drop-ins now also guards the unbundled shipped modes.

**Tests exercise the real install path.** `sandbox_install_mode` copies a packaged
extension's payload into the sandbox drop-in dir before boot; `modes.tcl` installs
emacs+vi and `vi.tcl` installs vi, so both suites test the modes *as extensions*,
through the same `modes_load` drop-in mechanism a user hits — not a shipped-file
shortcut. Full sweep stays green (311 core + every GUI suite).

---

### D42 — The files pane is a rich-list drawn with a text widget (not a listbox)

The files pane was a classic Tk `listbox` — text-only, one whole-widget colour, one
selection bar: "essentially the output of `ls`." To make it feel like Win98/2000-era
productivity software (per the UI principle) it needs per-row icons, a hover band,
and a proper selection band — none of which a listbox can do. So the pane body
becomes a **read-only `text` widget used purely as a rich-list canvas**: a Win2000
sunken white "well" holding one line per entry — a mono glyph icon (`▴`/`▸`/`▪`, all
U+25xx so they render monochrome, never emoji — honouring the icons-are-glyphs
principle) then the name; a full-width hover band and selection band (the tag spans
through the trailing newline so it fills the pane width). Navigation is **unchanged**
— still the flat, lazy one-directory `fs.list` navigator (`..`, descend, open); this
is purely how it looks and feels.

**The boundary that matters: this text widget is GUI-local chrome, NOT a core
buffer.** rio has exactly one "view of a core buffer" — the editor widget, renamed
to `::real<g>` and proxied so every keystroke is a `buffer.replace` over the protocol
(D3/D33). The files body is the opposite: `-state disabled`, never renamed, never
proxied, never editable, absent from the document model. It uses a text widget only
because it is the best stock classic-Tk surface for icons + full-width bands +
scrolling + keyboard nav (a canvas would mean hand-computing all of it). So this does
**not** put rio on the emacs "everything is a buffer" road; that stays a conscious,
not-yet-taken fork (ROADMAP). If rio ever *does* want core-backed read-only "view
buffers" (dired/git/log with modes), this widget could be re-backed then — but by
choice, not drift.

**Themed through the existing pipeline, no new roles.** `apply_theme` styles the well
(editor surface), the `selrow` band (`editor.selection`), a `hoverrow` band (a
`blend_hex` tint toward the selection), and the `navicon` glyph colour (a muted
`ui.fg`). `blend_hex` derives theme-relative shades so night-theme and custom themes
get a sane hover for free. The git pane keeps its listbox for now (a candidate to
adopt the same rich-list later — see D43). `smoke.tcl` drives the new widget (line
text, band tag ranges, key/click nav); full sweep green (311 core + every GUI suite).

---

### D43 — The rich-list becomes a shared component; the git pane joins it; the file pane shows git flags

D42 built the rich-list *for the files pane*. Two follow-ons: make the git pane look
and feel the same, and surface git status in the file pane. Both fall out of the same
move — **factor the rich-list into a reusable `rl_*` component** and make the two panes
instances of it.

**The `rl_*` component.** A rich-list is a read-only `text` widget drawn one row per
line, with the D42 full-width hover/selection bands and mouse+keyboard navigation. All
of that is now generic and keyed by the *body widget path*, so the file list and the
git list keep separate state (`::rl_rows($b)`, `::rl_sel($b)`, `::rl_hover($b)`) over
one implementation. Each row carries a `selectable` flag (placeholder rows like
`(clean)` aren't) and an opaque `payload` the owning pane interprets; the caller
renders its own row text (its glyphs/tags), the component only needs one inserted line
per `rl_row`. Two callbacks wire behaviour: `onselect` (click or arrow) and
`onactivate` (double-click / Return), either may be empty. The file pane passes
`{}`/`nav_open` (selection is inert; activating opens); the git pane passes
`git_pick`/`{}` (picking a change shows its diff — the old `<<ListboxSelect>>`
behaviour). This kept the panes' *meaning* in small pane-specific procs while the
chrome and feel are literally the same code. **One row selects at a time** — the
component has its own row model, and the `text` widget's native text-selection has no
place in it, so `rl_init` breaks every gesture that would begin or extend a `sel` range
(the drag `<B1-Motion>` and its variants, `<Shift-Button-1>`, `<Triple-Button-1>`,
`<Shift-Up>`/`<Shift-Down>`). `-state disabled` does *not* suppress that selection in Tk
— a drag over a read-only list still swept a stray multi-line highlight (spotted in the
files pane) until this. The git *diff* area below the list is a plain read-only `text`,
not an `rl_*` body, so it stays freely selectable for copying.

**The git pane is now a rich-list too.** Its `listbox` becomes the same sunken well +
read-only body; a change row is the two porcelain status chars (each colour-tagged by
kind — added green, deleted red, modified `accent`) then the path. The branch header,
Refresh button, and the collapsible diff area (D13) are unchanged. This is the
"adopt the same rich-list" candidate D42 flagged, done.

**Git flags in the file pane.** `populate_nav` now fetches `git.status` once and
annotates each row with a 2-char status gutter: a file gets its one-letter flag (the
worktree char, else the staged one), a directory gets a `·` rollup dot when it
contains — or *is*, since porcelain reports an untracked dir as itself — a change.
Same kind→colour tags as the git pane. Porcelain paths are repo-root-relative and rio
opens the repo root as the project, so they anchor at the project root; no repo (a
plain folder) means no gutter. No new theme roles — the flags borrow `diff.added` /
`diff.removed` / `accent`. It is still a *read* view (D7): flags are shown, not acted
on. rio does no file-watching, so rather than live, the panes refresh at the moments
rio *knows* the tree changed: opening a folder and **saving a file** both now call
`refresh_dock` (repaint the shown pane). That closes the obvious feedback loop — edit
in rio, save, see the `M` — without a watcher. What still needs a manual nudge
(navigate, or the git Refresh button) is a change rio didn't make: an *unsaved* editor
buffer (git reads the working tree on disk, so there's nothing to see yet) and edits
made *outside* rio. The general file-pane auto-refresh gap (ROADMAP) stays open.
`smoke.tcl` covers the git rich-list (row text, pick→diff) and the file-pane flags (an
`M` on a modified file, a `·` on a dir with an untracked child, and a flag appearing
after `do_save`); full sweep green.

---

### D44 — Right-click context menus on the panes; the first git write ops

The rich-list panes could show git state (D43) but not *act* on it — no way to track an
untracked file. So: **right-click context menus** on both panes, and the git actions
they need. "Track a file" is `git add`, which is the **first git write op in rio** —
git had been read-only since D7 (status/diffs). This deliberately extends that line to
**stage / unstage / track**; commit (needs a message UI) and discard (destructive)
stay out.

**Menus ride the `rl_*` component.** `rl_init` gains a third callback, `oncontext`; a
`<Button-3>` binding runs `rl_context`, which selects the row under the pointer
(band only — `fire=0`, so a git-pane right-click doesn't also load the diff) and hands
its payload + root coords to the pane's builder. Each pane keeps a tiny builder
(`nav_menu_build` / `git_menu_build`, split from the `tk_popup` wrapper so a headless
test can read the entry labels) that follows the existing `tab_context_menu` idiom —
a fresh menu per popup, scoped to the clicked row (the UI-design bar). The file menu
offers Open + Copy Path always, and git items from the row's status (read from the
`::nav_git` stash `populate_nav` already computes): untracked → *Track (git add)*,
worktree-dirty → *Stage*, staged → *Unstage*, a dir with changes → *Stage folder*. The
git-pane menu offers Open + Copy Path + Stage/Unstage from the change's X/Y.

**Core.** `git.add` (`git add -- <path>`) and `git.unstage` (`git reset -q -- <path>` —
`reset`, not `restore --staged`, so it also works on an unborn HEAD) join `rio::git`
and register like the read ops (D7/D11). They run core-side, so the menus work in
remote mode unchanged; the GUI's `do_git` calls the op then `refresh_dock` so the flag
/ change list updates immediately. Paths are the one wrinkle: the file pane holds
abspaths, the git pane holds repo-relative paths — both resolve against the project-root
cwd, so `do_git` passes either through untouched. Tested end to end: `git.test` covers
add/unstage incl. the unborn-HEAD case (core 318); `smoke.tcl` covers the menu-label
logic (Track vs Stage vs Unstage vs Stage folder) and the action path (stage→unstage a
file, pane repaints). File-management actions (New / Rename / Delete) and commit/discard
are recorded in ROADMAP, not built.

### D45 — git commit from the GUI: the first inline pane input

D44 let you stage but not commit — the loop dead-ended at the terminal. D45 adds
**commit**, and with it rio's **first inline text-input inside a dock pane**: an
*auto-showing commit bar* at the bottom of the git pane. It appears **only when the
index has a staged change** and hides when nothing is staged — the D36 find-bar quality
bar ("dynamic — appears only when needed") rather than VSCode's always-present box, so
the narrow dock carries no dead space and there's no button to hunt for. A single-line
summary entry + a *✓ Commit* button; Enter in the entry commits too.

**Why staged-only visibility.** Commit acts on the index. Showing the bar exactly when
something is staged makes the affordance self-explanatory (you staged → now you can
commit) and structurally prevents the "nothing to commit" error — the bar simply isn't
there when it would fail. `refresh_git` computes `staged` while drawing the change list
(any change whose X column is a real status char, not `" "` or `"?"` — the same test
`git_pick` uses) and calls `git_commit_bar`; every clean / no-repo early-return hides it.
The toggle is deliberately *not* a blanket hide-at-top, so staging another file (which
runs `refresh_dock`) doesn't wipe a half-typed message.

**Single-line, v1.** One summary line (`git commit -m`), matching rio's own commit style
and keeping the dock uncluttered; a multi-line body is deferred (ROADMAP). An empty
message is refused quietly in the GUI (a header flash, focus kept — no core call) rather
than letting git abort. Success feedback reuses the header: `git_flash` shows
`✓ committed <short-hash>` in the branch label and schedules a `refresh_git` to restore
it — no new status widget.

**Placeholder hint (later refinement).** The empty entry shows a greyed `message` hint —
Tk entries have no native placeholder, so it is a child label *placed inside* the entry
and toggled by the entry's textvariable trace (shown while empty, hidden the moment you
type). Kept out of `.msg get`, so the hint text can never be mistaken for a real summary
or committed; themed on the entry surface with a `blend_hex` grey. `smoke.tcl` covers the
empty→typed→cleared cycle.

**Core.** `git.commit` (`git commit -m <msg>`, returning the new HEAD short hash for the
flash) joins `rio::git` and registers like the rest — the second git write family after
D44, core-side so it works remote unchanged. We lean on git's own honest guards
(surfaced as `bad_request` by `_run`): empty message and nothing-staged both fail with
git's wording, no pre-checks. Tested: `git.test` covers commit-clears-index, the
unborn-HEAD first commit, and nothing-staged → `bad_request` (core 322); `smoke.tcl`
covers the bar's staged-only visibility and the commit action (empty no-ops, a real
summary commits + clears the entry + auto-hides the bar). This commit bar is also the
input primitive the deferred file-management verbs (Rename / New) will reuse.

---

### D46 — Highlighters can register by whole file NAME, not only extension

The syntax registry (D32) resolved a highlighter by file **extension** only. That is
fine for `.sql` / `.rb` / `.ts`, but the two most-reached-for build files carry **no
extension at all** — `Makefile`, `Dockerfile` — so they could never be highlighted. D46
adds a second, parallel key: `register_filename <lang> {basenames} <scan>` maps whole
basenames (`Makefile`, `GNUmakefile`, `Dockerfile`, `Containerfile`) to a scanner, beside
the existing extension map.

**Resolution precedence** (`rio::syntax::_resolve`, shared by `for_path` and
`lang_for_path`): exact basename → extension → **rootname-of-basename**. The rootname
fallback (last suffix stripped) means `Dockerfile.prod` and `Makefile.inc` still resolve,
while an *explicit* extension always wins first, so `Makefile.tcl` is Tcl — a rootname
guess never overrides a real extension. Case-insensitive throughout, "later registration
wins" unchanged (so a user file still shadows a shipped one). A language can register
under both keys: the Makefile highlighter claims `Makefile`/`GNUmakefile` by name *and*
`.mk`/`.make` by extension.

This is the enabling seam for the D32 "more languages" batch that shipped Makefile,
Dockerfile, Batch/cmd, PowerShell, awk, and sed — the build-file highlighters would be
dead code without a basename key. Kept deliberately small: no glob/shebang matching (a
`#!/usr/bin/awk` first-line detector is the obvious next step, noted but not built).

---

### D47 — The file pane auto-refreshes on out-of-buffer disk writes (`fs.changed`)

The files pane repainted only on an explicit reload (navigate away and back, or the
user's own Save). So an **agent-created file never appeared** until a manual refresh: the
core does no broadcast for a disk write that isn't backed by an open buffer, and
`buffer.changed` — the event the editor already listens to — only fires for buffer edits,
not for `fs.write` straight to disk. This was the long-standing file-pane gap.

The fix is one new event, mirroring `buffer.changed`. The `fs.write` op now returns an
**`fs.changed {path}`** event (the write-sibling of the buffer path: `buffer.changed`
covers open buffers, `fs.changed` covers the disk). The agent's `apply_write` **forwards**
it on the two paths that write disk directly — a `propose_create` and a closed-file
`propose_edit` — so an approved agent write reaches every connected frontend the same way
an edit does. (The open-buffer edit path already rides `buffer.changed`, so it needs
nothing new; and the file was already visible.) `file.save` deliberately does **not** emit
`fs.changed`: the user's own Save refreshes the dock locally in `do_save`, so emitting
would only double-repaint the initiating GUI — a second-frontend sync for user saves is a
separate concern, left out.

GUI side (`on_fs_changed`): the git pane's status is project-wide, so it always repaints;
the files pane is a **single-directory** navigator, so it repaints only when the change
lands in the directory currently shown (`file normalize` on both sides, since a write to
another subtree wouldn't be visible there anyway). Same seam is ready for the future
`fs.*` delete/rename ops (D-file-management): each should emit `fs.changed` on the
affected path and this handler already does the right thing.

Complementing the auto path, the files-pane header gained a **manual `⟳` Refresh**
(`.dock.files.hdr.refresh` → `populate_nav`), mirroring the git pane's header exactly
(the header became a name-left / glyph-right frame like `.dock.git.hdr`). Auto-refresh
only fires for writes rio's own core makes; `⟳` is the escape hatch for changes it
didn't — an external editor, a `git pull`, a build artifact — re-listing the directory
and re-reading git flags on demand.

Between those two, a **focus-return refresh** covers the same external-change case without
a click: rio re-syncs the shown dock pane whenever the application regains OS input focus
(`app_focus_event` → `refresh_dock`), the "I alt-tabbed back to rio" moment. It is not a
poll — one `refresh_dock` per app-return. The mechanism is deliberately GUI-side and
dependency-free (no inotify/kqueue): FocusIn/FocusOut on the toplevel bindtag, debounced
onto an idle callback that reads `focus -displayof .` (empty exactly when another app
holds focus), so only a genuine app-level false→true edge refreshes — within-app widget
moves don't. `note_app_focus` is factored out as the testable core (edge logic without a
real window manager). This is the cheap 90% answer; true live file-watching in the core
(emitting `fs.changed`) stays the deferred "proper" path in ROADMAP, with its dependency
and per-platform cost.

### D48 — File-management context actions: New / Rename / Delete

The file pane could browse and (D44) drive git, but not **manage** files — creating,
renaming, or deleting meant dropping to a terminal. This closes that loop with the
file-manager verbs off the row context menu: **New File / New Folder / Rename / Delete**.

The work is done **core-side**, as three new `fs.*` write ops beside `fs.write`, so it
works over a remote core exactly like `git.add` (the frontend never touches the disk):
`fs.create {path, ?type file|dir?}`, `fs.rename {path, to}`, `fs.delete {path}`. Each
mirrors `fs.write`'s shape — resolve against the project root, wrap the I/O in a catch
surfaced as `io_error`, and emit **`fs.changed`** so the D47 handler repaints without a
manual reload. Two deliberate safety choices live in the pure-I/O layer (`rio::fs`):
create and rename **refuse to clobber** an existing path (rename uses no `-force`), while
delete **is** recursive (`file delete -force`) so a folder goes in one call — gated behind
a GUI confirmation, since it's the one destructive verb. `fs.rename` emits **two**
`fs.changed` events (the old path and the new), so a move across directories repaints both
ends — `on_fs_changed` keys each repaint on the path's directory (the D47 seam anticipated
exactly this old→new pair).

**Open buffers are kept honest.** Renaming or deleting a file that's open in a tab can't
just touch the disk: the tab would still point at the old path. So the GUI **retargets**
open buffers — on rename, `retarget_buffers` rewrites each affected buffer's path (a
directory rename sweeps everything under it) both client-side (the tab retitles via
`tab_name`) and in the core via a new **`buffer.setpath {buffer, path}`** op, a no-write
path update (the same `rio::doc::setmeta` `file.save`'s save-as already uses). Without the
core half, the retargeted tab's next Save would recreate the *old* name from the core's
stale meta path — so `buffer.setpath` is what makes a rename durable. On delete,
`close_buffers_under` closes each affected tab; it clears the modified flag first so
`close_tab` (reused for its group-reactivation/collapse logic) doesn't offer to save a
file that no longer exists.

**Name input is a modal prompt** (`name_prompt`), not an inline pane bar — a decision
taken with jka. The auto-showing D45 commit bar proved the inline-input pattern, but a
small centred modal (New file name / New folder name / Rename to) is period-appropriate
(Windows-2000-era), simplest, and needs no theme wiring; rio's first custom modal input
(the others are `tk_messageBox`/`tk_chooseDirectory`). The inline in-pane rename stays a
noted deferral. Placement follows the flat one-directory navigator: **New** always creates
in the *shown* directory (`$::nav_dir` — "new here"; descend first to create inside a
subfolder), so it appears whenever a folder is open; **Rename/Delete** appear only on a
real entry *of* the shown directory (`[file dirname $path] eq $::nav_dir`), which
naturally excludes the ".." row and the no-folder placeholder. As with D47, the verb procs
(`nav_new`/`nav_rename`/`nav_delete`, doing the modal/confirm) are split from the testable
appliers (`fs_apply_*`, doing the core call + retarget + repaint) so the headless smoke
drives the effect without a dialog. Names are validated to a **single path component**
(no separators, not `.`/`..`) — nested-path creation from one prompt is a non-goal — with
a rejected name flashing the header (`nav_flash`, the files sibling of `git_flash`) and
changing nothing.

---

### D49 — Line-number gutter

A VSCode-style **line-number gutter** down the left of each editor group, on by default
(a decision taken with jka — it's a code editor), toggled by **View ▸ Line Numbers**
(`Ctrl+L`) and persisted in `prefs.json` (`line_numbers`) beside `wrap`/`wrap_indent`, so
the whole thing mirrors `::wrap_lines`/`apply_wrap` — a global view flag applied to every
group.

The gutter is a thin, unfocusable **canvas** gridded into column 0 (the text moves to
column 1, the tab strip spans all three), *not* a sibling text widget. The reason is
**wrap** (D-era `View ▸ Wrap Lines`): under wrap a logical line spans several display
rows, and a second text widget can't stay aligned. Instead `gutter_redraw` paints from the
text widget's own **`dlineinfo "$line.0"`** — the y-pixel of each logical line's *first*
display row — so a wrapped line shows its number once, at the top, exactly like VSCode, and
the two views can never drift. It walks only the visible logical lines (`@0,0` down to the
bottom pixel) and skips any line whose display box is empty (scrolled past / elided).

Repaint is driven by the two signals that mean "the view moved": the text widget's
**`-yscrollcommand`** (rewired to `edscroll`, which sets the group's scrollbar *and* marks
the gutter — this fires on every scroll and every edit that shifts a line) and its
**`<Configure>`** (resize / re-wrap). Both funnel through `gutter_mark`, which coalesces to
a single `after idle` pass so a fast scroll paints once. The gutter **width** tracks the
last line's digit count (floored at two digits) and is set even while the window is
off-screen — width needs only `[$t index end-1c]`, not a render — so it's stable and
headless-testable; the numbers themselves need a mapped window (dlineinfo has no geometry
otherwise), which is the one part the withdrawn smoke can't assert (the standalone draw
mechanism was verified separately). Colours reuse the existing **`gutter.fg`** role over
`editor.bg`, wired in `restyle_group` so a theme switch repaints. The gutter's mouse wheel
forwards to the text so a scroll begun over the numbers still moves the buffer.

**Non-goals (noted):** click-a-number to select the line, relative line numbers, and line
numbers in the side-by-side compare panes — all deferred; the gutter is the editor groups
only.

---

### D50 — Cursor position (Ln/Col) in the status bar

The status bar carries a compact **`Ln L, Col C`** segment for the focused group's insert
mark, between the language and buffer-count segments. It's computed by `cursor_status`
(reads `[fgw] index insert`, splits on `.`, reports `char + 1` so the column is 1-based like
VSCode/most editors while Tk indexes from 0) and rendered as one more `%s` in
`refresh_status`'s single-label format — no extra widget, in keeping with the one-label
status bar.

Keeping it live is two bindings per group (`make_editor_group`): **`<KeyRelease>`** and
**`<ButtonRelease-1>`** call `cursor_moved $g`, which repaints only when `$g` is the focused
group (a background split never owns the shown position). KeyRelease covers arrow/nav keys
and typing; ButtonRelease covers click-to-place and the end of a drag-select. Edits already
route through `refresh_all`, so this adds coverage for *pure navigation* that doesn't touch
the buffer. `cursor_status` is guarded (no focus / no group / a failing `index` → `""`) so
an early or transitional call is a harmless empty segment, not an error — the same defensive
shape the gutter's redraw uses. Selection extent (VSCode's "(N selected)") is deliberately
left out; the ask was line/column, kept compact.

---

### D51 — Find in Files: a core engine + a bottom results panel

The D36 note promised it: **find-in-files is *necessarily* core-side**, because in remote
mode only the core can see the project tree. So the engine is one op, **`project.search
{needle, ?nocase?}`**, that walks the open project (`rio::project::search`, over
`rio::fs::listdir` + `rio::fs::read`) and returns every matching line **grouped by file**:
`{count, files, truncated, results:[{path, rel, matches:[{line, col, text}]}]}`. This is
the one **two-level** result in the protocol, so the wire layer spells both nesting levels
out in a registered shape encoder rather than guessing (D25). The in-buffer search (D36) and
this now share a single search architecture, not two — exactly the payoff D36 predicted.

Scope is deliberately small for v1, mirroring `buffer.find`: a substring match with optional
`nocase` and `wholeword`. It skips the VCS dir (`.git/`), binary files (a NUL byte), and
oversized files, and caps result **rows** (surfaced as `truncated`) so a broad needle can't
walk away with the core. `count` is total **occurrences** (a line with two hits counts twice)
while the list shows **one row per matching line** (jumping to the first hit) — the VSCode
convention. **Whole-word** is a boundary test the engine applies itself (`_word_bounded`: a
hit counts only when neither flank is a letter/digit/underscore, Unicode letters included) —
the `\m…\M` feel without a regex per line. Each matching line also carries **`cols`**, the
1-based start column of *every* occurrence on it, so the frontend can highlight each hit
rather than re-deriving matches from its mirror (the D36 dumb-view discipline). Regex / glob
filters, Replace-in-Files, and one-row-per-match are left deferred.

**The results surface in a bottom panel**, decided with jka against a dock tab or a separate
window. This is the load-bearing UI choice and it is the **Visual Studio "Find Results" tool
window** (D35's north star made concrete): documents stay in the center, this is a *tool
window docked at the bottom* — the first small paving stone toward the deferred dock-site
system, built as one bottom strip (`.results`, packed `-after .status -side bottom` like the
find bar) rather than a general dock. It is a query row (needle + Match case + count + ×)
over an **`rl_*` rich-list** (the same reusable list the files/git panes use, D42/D43): a
non-selectable file-header row then one selectable row per match, whose payload is the
location. Match/Whole-word are checkboxes on the query row (each re-runs the search). Every
hit on a row is tinted with the **`fimatch`** band, which reuses the theme's `diff.added.bg`
(a light green on light themes, a dark green on dark ones — always readable under `editor.fg`,
raised above the selection band); the columns come straight from the op's `cols`, offset by
the `"<line>  "` row prefix. `Ctrl+Shift+F` / *Find ▸ Search…* opens it (seeding from
the selection like the find bar); double-click / Return on a match opens the file and jumps
the caret to the line. Search runs on Enter, not per-keystroke — it walks the tree, unlike the
in-buffer bar's live paint. The panel is transient (not persisted), like the find bar.

One trap met again: `fif_activate` (now `search_activate`, D52) uses the group's widget
**command** (`gw`) for `mark set`/`see` but the window **path** (`gget … path`) for `focus`
— the same command-vs-path distinction the D49 gutter bug turned on.

---

### D52 — the Search panel: two engines, three scopes, one grown surface

The open question from the D35 refinement (#5) was whether the inline find bar should fold
into the bottom panel like Notepad++'s one "all things search" dialog. **Decided with jka:
keep them as two jobs, connected, not one.** The inline bar (D36) stays the quick in-buffer
path — jka values its low-fuss immediacy — and the D51 find-in-files panel **grows into a
unified Search panel**: find across three **scopes** in one bottom tool window, with the bar
gaining an *escalate* handoff into it. Both sit on one core engine, so they can never disagree.
This *refines* D35 (the panel is the concrete bottom-site tenant; since D35 landed it is a
normal dock tenant with its **own in-body header** — `.results.hdr` — like Files/Git/Agent, per
D35's settled chrome rule; a tab-strip fold was tried and rejected) and supersedes D51's
narrower scope.

**Two engines behind a scope selector.** Matching stays core-side (the D36 discipline), and
the line-grouped matcher D51 buried in `project::_search_file` is extracted to a shared
**`rio::doc::grep_lines {lines needle nocase wholeword}`** → `{line, col, cols, text}` rows, so
the disk walk and the buffer walk use *one* matcher:

| Scope        | Op                              | Reads                          |
|--------------|---------------------------------|--------------------------------|
| Project      | `project.search` (D51)          | the on-disk tree               |
| Open docs    | **new** `buffers.search`        | every open buffer's live text  |
| Current doc  | `buffers.search` with `only`    | the focused buffer             |

`buffers.search {needle, ?nocase?, ?wholeword?, ?only?}` iterates `rio::doc::inventory` and
returns the **same** two-level shape as `project.search` but with per-buffer headers
(`{buffer, name, path, matches:[…]}`); the wire encoder shares the envelope + line-match
encoding with `project.search` and differs only in those header keys. `truncated` is always 0
(the open set is bounded and in memory). The buffer scopes read **live** text, so they reflect
**unsaved edits** — the useful "in opened documents" semantic, distinct from Project's on-disk
view. `project::_search_file` now just reads the file, splits, and calls `grep_lines` (the
refactor is inert — every D51 case still passes).

**The GUI is the D51 panel, generalized** (the `.results.*` widget paths are kept to limit
churn; `fif_*` → `search_*`). The query row gains a **scope option menu** (`tk_optionMenu`
driving `::search_scope`, each entry re-running the search). `search_run` routes by scope;
`search_paint` renders a file object carrying *either* `rel` (a disk header) or `name` (a
buffer header), and rows whose payload carries *either* `path` (→ `do_open`) or `buffer` id
(→ `activate`); `search_activate` branches on which — so one render + one activate path serve
every scope. The result count's noun follows the scope (files vs buffers). The **escalate**
handoff: `Ctrl+Shift+F` while a find-bar entry is focused (`search_from_bar`) carries the
bar's needle + `::find_case`/`::find_word` into the panel and widens the scope to Project (the
point of escalating). Relabelled *Search…* throughout (menu, keymap action `search`, panel
label); `Ctrl+Shift+F` is unchanged.

**Phasing. Phase A** was search only; **Phase B — Replace** and **Phase C — Regex** (both
below) are now in. Re-homing the panel into the D35 bottom dock-site is **done**: it is a normal
bottom-site tenant carrying its query row in its own in-body header (`.results.hdr`), per D35's
settled chrome rule — the tab strip stays tabs-only.

**Phase B — Replace across the scopes.** The panel gains a **replace row** (a replacement
entry + Replace All, toggled with `Ctrl+H` like the bar; the bar's escalate carries its
replacement text and opens the row when the bar was in Replace mode). `search_replace_all`
routes by scope:
- **Buffer scopes** (Current doc / Open docs) → `buffer.replace_all` — one undo step per
  buffer, the change left **unsaved**; each touched buffer is flagged modified. Open docs
  loops every open buffer; Current doc hits just the focused one.
- **Project** → a new **`project.replace {needle, text, ?nocase?, ?wholeword?}`** op, gated by
  a GUI **confirm** (it can write disk). It reuses `project.search` to find the matching files
  (same `.git`/binary/oversized skips), then **routes each by whether it is open in the
  editor** — the same open-vs-closed split the agent's writes use (agent-tools `apply_write`):
  an open file is replaced **through its buffer** (`rio::doc::replace_all`, undoable, unsaved,
  a `buffer.changed`), a closed file is **rewritten on disk** (`rio::fs::write`, encoding/EOL
  preserved, an `fs.changed`). Routing open files through the buffer is the **divergence
  guard**: disk is never rewritten under an open view. It returns `{count, files, bufferids}`;
  the GUI flags the returned `bufferids` modified (their changes are unsaved). The replace uses
  the shared **`rio::doc::_replace_text {old needle text nocase wholeword}`** pure string
  function, extracted from `replace_all` so the buffer path and the disk path share one matcher
  — the mirror of how `grep_lines` unified the search side. A key implementation trap: because
  `project.replace` mutates buffers/disk *and* returns a batch of events, it must NOT drive its
  sub-work through nested `rio::core::call` (that shares one `evbuf` and would double/leak
  events into the outer batch); it calls the model functions directly and shapes the events
  itself. After a replace the old hit locations are stale, so the list is cleared and the count
  line reports what changed.

**Phase C — Regex.** A `regex` flag rides every search/replace op (`buffer.find`,
`buffer.matches`, `buffer.replace_all`, `project.search`, `buffers.search`, `project.replace`)
and both GUI surfaces (a **Regex** checkbox on the find bar and the Search panel). When on, the
needle is a **Tcl ARE** pattern. Three decisions, settled with jka:
- **Line-oriented** (`regexp/regsub -line`): `^`/`$` anchor at each line boundary and `.` /
  negated classes do not cross a newline — the predictable editor default, and it matches the
  line-grouped panel naturally. `nocase` maps to `-nocase`.
- **Whole-word is superseded** — a pattern writes its own boundaries (`\y`, `\m…\M`), so the
  Whole-word box greys out while Regex is on (`find_regex_changed` / `search_regex_changed`).
- **Backreferences in Replace** — replacement is a `regsub` subSpec, so `\1`/`&` resolve
  against the match (the two-step find-bar Replace does the substitution **client-side** on the
  already-matched selection — a presentation concern, not matching over canonical text).

Regex matching centralizes in **`rio::doc::_regex_spans {hay pat nocase}`** → a list of
`{start end}` char-offset spans: `-about` gives the capture-group count so submatches (which
`-all -inline -indices` interleaves) are strided over; an **invalid pattern is caught and
treated as "matches nothing"**, never an error, so a half-typed regex under a live search just
shows no hits. `find` computes the span set once and picks next/prev with wrap; `matches` maps
spans to line.col; `_replace_text` delegates to `regsub -all`; the per-line `grep_lines` runs
spans per line. Because a regex hit is **variable-length**, each line-match row now carries a
parallel **`lens`** array beside `cols` (start column + char length per hit), so the panel's
green band sizes to the actual match rather than a fixed needle length — the one wire-shape
change (a `lens` array in `_linematch`).

### D53 — LLM integration: assisted, not autonomous (the line is *autonomy*, not *capability*)

How far should rio's agent go? The agent today reads the project and proposes edits behind a
diff + approval (D8, D14, D20). The open question was whether the roadmap's run-command tool,
test-running, and runtime use push rio toward being an **agent harness**. **Decided with jka:
the line is drawn at *autonomy*, not *capability*.**

- **In scope — capability is not the limit.** rio's LLM integration MAY do the full in-session
  toolset: write files, write tests, **run tests, run commands, use runtime environments** — all
  **with a human present and in the loop**, in the propose/approve, human-driven posture. The
  run-command tool (ROADMAP, "under explicit approval/confinement") is therefore squarely in
  scope; running tests needs it. What gates a command is *approval*, not a ban.
- **Out of scope — on identity, not deferred.** rio acting **on its own when no human is
  interacting**: cron-driven, unattended, self-directed "go do things while nobody watches"
  operation. rio does not head toward being an agent harness in that sense. This is the Win98/2000
  conservative posture applied to LLMs — a capable assistant you drive, not an automation daemon.
- **The constraint binds rio itself, NOT plugins.** A plugin author may build unattended /
  agentic behavior on the plugin surface (D16–D19); rio's own restraint is not imposed on them.
  This mirrors the extension stance (D39): rio holds a conservative line for itself without
  caging what others may publish.

Practical test when a feature is proposed: does it need a human in the loop to act? In scope.
Does it act unattended, on a schedule or its own initiative, with no human present? Out.

### D54 — Every entry point pins the source encoding to UTF-8

rio's sources are UTF-8 and carry non-ASCII deliberately: D27's whole iconography is
monochrome Unicode glyphs (`●` `⟳` `▸` `✓` `×` `·`) written as literals, plus em
dashes and ellipses in user-facing strings. **Tcl 8.6 decodes a script file with the
`encoding system` value, not UTF-8** — and on a Western Windows install that is
cp1252. The first native Windows run (RELEASING.md Gate 0) therefore rendered every
one of those glyphs as mojibake: the title bar read `rio â€" untitled`.

**Decision:** every file that is *run* rather than *sourced by another rio file* —
`rio-gui/rio-gui.tcl`, `rio-core/server.tcl`, and each `rio-gui/tests/*.tcl` — opens
with the same four-line guard:

```tcl
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
```

Setting the system encoding fixes every file sourced *below* it, so the guard is
needed only at entry points; the re-read fixes the entry file's own literals, which
were already decoded before line 1 ran. Placed as the first executable statement it
repeats no work, and it is a **no-op** wherever the system encoding is already UTF-8 —
Linux, the BSDs, and Tcl 9 everywhere (Tcl 9 defaults `source` to UTF-8, which is what
makes this a 8.6-shaped problem that will age out rather than a permanent tax).

**Why not `\u` escapes instead.** Escaping the ~21 distinct glyphs at 192 call sites
would also work and needs no global state, but it trades a readable UI vocabulary for
unreadable source at every use, and it would not help the next contributor who types a
real character. The guard fixes the class, not the instances. Escapes are still the
right answer in one place: a **test's expected value**, which is compared against a
correctly-decoded runtime result and so must not depend on how the test file itself
was read (see `rio-core/tests/fs.test`).

**Why setting `encoding system` globally is safe here.** rio never relies on the
default: `rio::fs::read`/`write` open `rb`/`wb` and call `encoding convertfrom`/
`convertto` explicitly to implement D22's detect-and-preserve, every config reader
pins `-encoding utf-8`, and so does the wire channel on both ends. The only thing the
setting changes is how Tcl reads *rio's own source*, which is exactly the bug.

### D55 — The core answers questions about its own host; the frontend never guesses

A frontend is a thin view onto a core that may be running on **another machine, on
another platform** (D30). So any fact about *where the files are* belongs to the core,
and a frontend that computes such a fact locally is guessing — correctly by luck on a
matched pair, and wrongly the moment they differ.

The case that forced this: `rbrowse_start` hardcoded `"/"` as "where the Open/Save
browser opens when there is no seed and no project". That is right for a POSIX core
and wrong for a Windows one, whose root is `C:/` — `/` there is not even an absolute
path (Tcl calls it `volumerelative`), so the browser opened on an unlistable path.
Substituting the *client's* own root would have been just as wrong in the other
direction: a Windows GUI on a Linux core would have offered `C:/` for a filesystem
that has no such thing.

**Decision:** `session.hello` reports **`fsroot`**, the root of the core's filesystem,
and the GUI records it per attachment (re-read on reconnect, since the new core may be
a different host). Sibling facts can join it there as they are needed; the greeting is
already the place a client learns what the core is.

Two consequences worth stating:

- **It does not bump `protocol`.** The field is additive: an older core omits it and
  the client keeps its default. That is D19's forward-compatibility rule — unknown
  keys ignored, absent keys defaulted — applied to the protocol itself rather than to
  extension manifests. A version bump is for changes that *break* a peer.
- **Shape-based path tests stay.** `core_path_absolute` judges a path by its shape (a
  leading `/`, or an `X:` drive prefix) rather than by `file pathtype`, which answers
  with the *client's* rules. `fsroot` tells the GUI where to start; the shape test
  tells it what an absolute path looks like. Both are needed, and neither is
  `file normalize`, which on a Windows client rewrites `/home/jka` to `C:/home/jka`.

The general rule, for the next time this comes up: **if the answer depends on the
core's host, ask the core.**

### D56 — The editor font is a user override layered on the theme's named font

The document view's font has always been `RioEditorFont`, a **named** font the theme
supplies (D24: fonts are theme data, referenced by name so a change is live). That is
the right owner for a font's *default*, but the user needs to set family and size for
themselves — and zoom them on the fly while reading a logfile — without editing a theme
file.

**Decision:** keep the theme as the source of the default, and add a thin **user
override** on top of it, owned by the GUI as a preference (D31), not by the core. Two
prefs — `font_family` (`""` = follow theme) and `font_size` (`0` = follow theme) — are
overlaid onto the theme's own family/size in one place, `apply_editor_font`, which
reconfigures the single named font (live everywhere) and repaints the per-group chrome
whose geometry tracks glyph width (the gutter and the wrap-indent margins). `apply_theme`
records the theme's editor family/size and then calls `apply_editor_font`, so a **theme
switch keeps the user's choice** instead of silently discarding it — the explicit
override outranks the theme until the user resets it.

**Absolute, not a delta.** A zoom step pins an absolute size (clamped 5–72), so the
choice is stable across theme switches and reloads. `Ctrl+0` (or the picker's *Use Theme
Font*) drops the override back to `0`/`""` and the view follows the theme again.

**Why the zoom keys bypass the keymap (D23).** `Ctrl+scroll`, `Ctrl +/-` and `Ctrl+0`
bind directly on the editor widget and its gutter, not through `::keymap` — they are
fixed accelerators like the compare pane's `Esc`, not user-remappable commands. Both the
X11 (`Button-4/5`) and Windows/macOS (`MouseWheel` + `%D`) wheel idioms are wired,
matching the plain-scroll bindings the gutter already carried; `break` stops a
`Control`-wheel from also plain-scrolling via the Text class binding. Scoped to the
document view on purpose — the UI and chat fonts stay theme-controlled.

---

### D57 — When tabs outrun the strip: page them, wrap them, or list them

A narrow window used to strand tabs off the right edge of a group's strip with no way to
reach them (Notepad++'s long-standing gripe). Three complementary answers, all wanted:

**A always-reachable list.** Originally a top-level **Tabs** menu (`.m.tabs`, rebuilt each
open via `-postcommand tabs_menu_fill`) listed every open buffer across every group by name.
It is the reliable escape hatch — a tab is a couple of clicks away no matter how little strip
there is. This is the safety net; the two visual modes below are the in-strip conveniences.
(**Retired into a bounded dialog in D74**: that cascade was the one unbounded menu that could
grow screen-tall on X11, so it became **View ▸ Switch to Tab…**, a listbox picker — which
also shows a path hint to tell same-named tabs apart. The picker is shared with Compare ▸
Compare With Another Tab…; see D74.)

**Two strip modes, a persisted View preference (`::tab_layout`).** `scroll` (default)
keeps the tabs on **one line** and, when they overflow, shows `◂ ▸` arrows that page a
visible *window* of tabs (a per-group `taboff` index into `gorder`). `multi` **wraps**
them onto as many rows as the width needs. The choice rides in `prefs.json` like the
other view state (D31); a bogus value is rejected back to `scroll`. The **Multi-Line
Tabs** checkbutton lives in the **View** menu, with its display-toggle neighbors (Wrap,
Line Numbers) — the Tabs menu is a pure buffer list. (It shipped in the Tabs menu; moved
to View in the D-after-57 preferences work, where the mismatch — a persistent view
preference grafted onto a `-postcommand` navigation list — was the tell.)

**One layout choke point.** `refresh_tabs` builds the tab *handles* (the `b<id>` frames)
but leaves them unmanaged; **`tabstrip_layout`** places them — `pack` on one row for
`scroll`, and for `multi` a `pack` flow across **one row-frame per visual row**
(`tabstrip_row` makes each `r<n>` container; D78 — it was originally `grid`, which forced
uniform column widths and both huddling gaps and right-edge clipping) — and runs again on
the strip's `<Configure>` so a resize re-flows. Widths are measured **analytically** (`tab_pixwidth` via `font
measure`, mirroring the handle's own padding) rather than from `winfo reqwidth`, so the
layout is correct *synchronously* — before the handles are mapped — which is also what
makes it testable without an event loop. The editor pane is a fixed share of the window
(a stretched panedwindow pane over an 80-column text, toplevel propagation off since
D35's `sash_drag`), so the strip never grows to swallow its tabs: overflow is real and
driven by tab count, and `tabstrip_fit_last` always keeps at least the first tab so a
sliver of space never strands the lot.

**Reveal vs. page.** `tabstrip_layout` pulls the visible window to include the active tab
by default (`reveal`), so activating a tab — from the strip, the Switch to Tab… dialog, or a
keystroke — scrolls it into view. The arrows call it with `reveal` **off**, so paging can
move *past* the active tab to reach a hidden one and click it (which then activates and
reveals it). The arrows live in the strip alongside the `b<id>` handles as `al`/`ar`, so
generic "children of the strip" scans (e.g. the smoke suite's tab enumerator) must select
`b*` handles, not every child.

---

### D58 — A central Preferences window that owns no state

The top-level menus were starting to accrete settings (D57 parked the Multi-Line Tabs
toggle in the *Tabs* menu, of all places — a persistent view preference grafted onto a
`-postcommand` navigation list; that mismatch was the tell). As the count grows we want
one place to find every setting. Two decisions kept it cheap and non-duplicative.

**It owns no state.** Every control drives the **same global** its menu twin binds
(`::wrap_lines`, `::tab_layout`, `::edit_mode`, `::agent_provider`, …) and calls the
**same applier** (`apply_wrap`, `tab_layout_apply`, `apply_editmode`, `apply_provider`,
…), each of which already persists via `prefs_save` (the "single choke point per setting"
contract). So the window is a **second door** to the settings, not a copy of them: change
one, and because the menu checkbutton shares the `-variable`, Tk repaints it the instant
the global changes — and vice-versa — with **no re-sync code**. The theme control is a
**dropdown** (a menu can install arbitrarily many themes, D39; a radio stack does not
scale) whose collapsed button shows the current theme's pretty label plus a `▾` chevron —
a bare Tk `menubutton` draws no arrow of its own and reads as a plain button, so the
glyph (mono-Unicode, per the icon rule) is what signals "opens". The display string lives
in `::theme_choice_label`, which a lone lifetime trace keeps tracking `::theme_choice`
(via `theme_choice_display`); the menu entries and the editing-mode radios are enumerated
from the core / the `rio::modes` registry (like `themes_menu_fill` / `modes_menu_fill`),
so installed themes and mode extensions appear here too.

**Live-apply, not Save/Cancel.** Every view toggle in rio already takes effect the moment
you flip it; a Preferences window for those must do the same, so there is no working copy
and no OK/Cancel — a toggle is instant and persisted. This is the deliberate opposite of
the keyboard-shortcuts recorder (D23), whose working-copy + Save model is right *there*
because a half-recorded chord must not apply live. Keyboard shortcuts therefore stay their
own editor, reached from a "Keyboard" category button rather than reimplemented.

**Scope: stateful settings only.** Preferences are *state* (wrap, line numbers, tab
layout, theme, editing mode, agent options); commands (Zoom, Split, Compare With File) are
*actions* and stay menu-only. The window is a non-modal toplevel `.prefs` — a category
listbox on the left, one body frame per category raised on selection (a notebook without
the widget), themed via the `prefs_check`/`prefs_radio`/`prefs_label`/`prefs_button`
factories. Opened from **Settings ▸ Preferences…** and a `preferences` keymap command that
ships **unbound** (empty chord — no collision), so a user can assign one in the recorder.

---

### D59 — Menus highlight on hover, not on the click that opens them *(reverted)*

**Reverted.** The intent was to fix a click/hover inconsistency in Tk's default menus:
**clicking** a menubar item posts its dropdown and highlights the **first entry** (Tk's
`MenuInvoke`, on a mouse-button release over a cascade, calls `MenuFirstEntry` —
`menu.tcl`), while **sliding** the pointer to an adjacent menu posts it with nothing
highlighted. The shipped fix (X11 only) set a `::rio_menu_click` flag around a *replaced*
`Menu <ButtonRelease>` class binding and renamed/wrapped `tk::MenuFirstEntry` to skip the
first-entry activation on the mouse path.

That mechanism reached into Tk's own menu **grab/post/invoke state machine** — the one it
patched to read as narrow — and in real use produced **intermittent misfires**: a click
that immediately invoked the dropdown's first item, and clicks that stuck (a post that
didn't settle). Rebinding the shared `Menu` class's release and interposing on
`MenuFirstEntry` is too coupled to Tk's internal event/grab ordering to be reliable, so it
was removed and menus are back to **stock Tk behaviour**. The cosmetic click-vs-hover
first-entry difference is accepted. The `rio-gui.tcl` site carries a "don't re-add"
breadcrumb; the guard test (`tests/menubar.tcl`) was deleted with the code. If the polish
is wanted again, it needs a mechanism that does **not** rebind `Menu <ButtonRelease>` or
override the `MenuFirstEntry`/`MenuInvoke` machinery.

---

### D60 — Current-line highlight

The editor tints the **logical line the insert caret sits on** with a faint full-width
background band — the near-universal editor affordance (VSCode's "highlightActiveLine").
**On by default;** a toggle sits with the other display switches in **View ▸ Highlight
Current Line** and in the Preferences window's View category (the same global,
`::highlight_current_line`, driven through the same applier — the two-door pattern of D58,
so menu and window stay in sync for free).

It is a **pure display layer**, like the line-number gutter (D49) and wrap-indent: a
`curline` text tag, added over `insert linestart … insert lineend +1c`. The `+1c` reaches
into the newline so the band spans the **full width**, and because the range is the whole
*logical* line it covers every display row of a wrapped line. Nothing enters the buffer
text. The band is **per group** — a split shows it under each pane's own caret — and is
recomputed wherever the caret can move: `cursor_moved` (typing / arrows / click, per
group), `refresh_status` (open / tab-switch / goto / reload, which all route through it),
and the search-result jump (which lands after `activate`'s status refresh).

**Colour.** A new theme role, `editor.currentline` (default `#eef2f7`), so a theme owns
its band the way it owns `editor.findmatch` (D36); `restyle_group` falls back to a faint
blend of `editor.bg` toward `editor.fg` for a theme predating the role. The tag is
**lowered** to the bottom of the priority stack, so syntax colours (foreground only) read
over it and the selection / find-match / column bands paint above it.

### D61 — Click a gutter number to select its line

The line-number gutter (D49) becomes interactive: **click a number to select that whole
logical line, drag to extend** the selection line-by-line, up or down — the familiar
VSCode / editor gesture. An added binding on the gutter canvas, riding the existing seam;
no structural change, GUI-only, core untouched.

The gutter is a canvas whose y-space **equals** the text widget's — `gutter_redraw` draws
each number at the text's own `dlineinfo` y — so a click y inverts straight back to a
logical line with **`index @0,$y`**, exactly reversing how the numbers are placed.
`gutter_press` anchors at the pressed line; `gutter_motion` extends the inclusive span
`anchor..current` (min/max swapped, so both drag directions work). The selection runs
`$a.0 … "$b.0 lineend +1c"` — the same `lineend +1c` newline-reaching trick as D60's band,
for a full-width line select that **clamps to `end`** on the last, newline-less line. The
gutter is `-takefocus 0`, so the press moves keyboard focus to the text itself
(`focus_group` + an explicit `focus`); `cursor_moved` then refreshes the status Ln/Col and
the D60 current-line band (which follows the caret to the next line's start, as in VSCode).

### D62 — Hide dotfiles in the Files pane

The Files navigator **hides dotfile / hidden entries by default** — `.git/`, `.gitignore`,
and friends — the way `ls` does, with a **View ▸ Show Hidden Files** toggle (mirrored in the
Preferences window's View category) to reveal them. Default off suits the Unix mental model
and de-clutters the flat one-directory navigator; the classic Windows Explorer "Hidden
items" checkbox is the same affordance, so a View-menu home reads as intuitive.

The filter is one line in `populate_nav`: skip an entry whose name starts with `.` unless
`::show_hidden`. It lives at the render loop, so the `..` parent row (rendered explicitly,
not from `fs.list`) is never filtered, and the core's `fs.list` is untouched — this is
GUI-local chrome, consistent with the pane being GUI-local (not a core "view buffer").

The toggle extends the two-door pattern (D58) to a **third door**: the View menu
checkbutton, the Preferences window check, **and a glyph button in the Files-pane header**
(next to the ⟳ refresh) all drive the same `::show_hidden` global through the one applier,
`apply_show_hidden`, which repaints the pane (`populate_nav`), persists (`prefs_save`), and
re-syncs the header glyph. The header button is the odd one out — a bare `label` +
`<Button-1>` (rio's header-control idiom; a hover tooltip names it, D63), so it also
**reflects state in the glyph itself** for at-a-glance reading:
`nav_hidden_glyph` shows a filled **◉** when hidden files are visible
and a faint dotted **◌** when they are hidden — the dotfile "dot" present vs. ghosted, both
monochrome U+25xx (the iconography rule). The menu/prefs checkbuttons repaint their own
checkmark from the `-variable`; the label can't, so every door funnels through
`apply_show_hidden` and the boot applier calls `nav_hidden_glyph` once so a persisted
on-state shows on startup. Round-trips through `prefs.json` like the other view flags.

### D63 — Hover tooltips for glyph controls

rio's little header controls are **bare glyphs** — the ⟳ refreshes, the D62 ◉/◌ hidden
toggle — with no text label to say what they do. A small **hover tooltip** names them.
`tooltip $w $text` is the whole public surface: it stashes the text (in `::tt_text($w)`)
and binds `<Enter>`/`<Leave>`; a single shared borderless toplevel `.tt` is built lazily
and reused, shown ~600 ms after the pointer settles (one `after` timer in `::tt_after`,
cancelled on leave) just below the control, nudged left if it would run off-screen.

**Look:** the classic Windows info-tip — pale yellow `#ffffe1`, black text, a 1 px dark
border (the toplevel's black background showing past a 1 px-padded label). Deliberately
**theme-independent**: a tooltip is momentary chrome that never has to match the pane
behind it, and the Win98/2000 info-tip is instantly legible in any theme (black on yellow).
This is the one spot that opts out of the theme roles by design.

**Stateful labels:** re-calling `tooltip $w $text` just overwrites the stash (no re-bind
churn), so a control whose meaning flips can re-label itself — `nav_hidden_glyph` sets
"Show hidden files" / "Hide hidden files" alongside the ◉/◌ swap. Hiding is on `<Leave>`
plus a best-effort `<ButtonPress>` (shadowed on controls that already bind `<Button-1>`,
where `<Leave>` covers it). Attached to the files/git Refresh glyphs and the hidden toggle;
the same one-liner extends to any future bare-glyph control.

### D64 — Keep the View menu within screen height (grouped, not tall)

A stock-Tk symptom on X11: a menu posted **taller than the screen space below it** unposts
when the pointer hovers an item mid-list. The **View menu** was the offender — it had grown
into a junk drawer (~23 items + 7 separators ≈ 30 rows; D60's Highlight Current Line and
D62's Show Hidden Files were the latest additions), while File/Edit/Settings (~11–15 rows)
fit and behave.

The fix is to keep the menu **short enough to fit**, not to touch Tk's menu machinery — the
D59 revert is the standing lesson that patching Tk's post/grab/scroll internals is too
fragile. Less-frequent items fold into three topical cascades — **Dock Side** (Left/Right),
**Font & Zoom** (Font…, Zoom In/Out/Reset), **Editor Layout** (Split / Unsplit / Move Tab)
— built like the existing `.m.view.theme` cascade. (Compare later left Editor Layout for its
own top-level menu — see **D73**.) The often-flicked **display
toggles** (Wrap, Indent, Line Numbers, Highlight Current Line, Multi-Line Tabs, Show Hidden
Files) and the four panel toggles stay at the top level. Result: ~15 items + 3 separators ≈
18 rows, comparable to Edit, so it posts and hovers as stock Tk.

Coupling from the move: `refresh_accelerators` retargets Split Editor / Move Tab to
`.m.view.layout`; a couple of tests address the moved items by their submenu path. A
`smoke.tcl` guard asserts `.m.view index end` stays small and the three submenus exist, so a
future addition can't silently re-inflate the top level past a screen again. **General rule:
a rio menu is kept within screen height by grouping, since Tk's off-screen menu posting is
not something we patch.** The underlying X11-only quirk (and the at-scale plan for the
unbounded Theme/Tabs menus) is logged in [CAVEATS.md](CAVEATS.md).

---

### D65 — A second agent provider (OpenAI-compatible), and hardening the provider contract

The agent had exactly one real provider (Claude, D26) besides the echo stub. Adding a second
is the point where a provider *contract* is either proven or found wanting — so it was done
now, in-tree, deliberately, both to ship the provider users asked for and to harden the seam
**before** it is ever frozen for outside contributors (milestone B, below).

**The provider is OpenAI-*compatible*, not ChatGPT-locked** ([plugins/openai/](plugins/openai/)).
Hosted ChatGPT (`api.openai.com`) is the default endpoint, but the endpoint is config-as-data,
so the *same* code drives a local OpenAI-compatible server (Ollama / llama-server / LM Studio /
vLLM) by pointing `messages_url` at it — exactly the in-box **local-LLM** provider D8 always
named. Sanctioned path only: the OpenAI **API** with the user's own key (0600, D21), never the
ChatGPT web UI. The plugin mirrors the Claude one — a loader, a thin auth face (Bearer, vs
Claude's `x-api-key`), and an inference core mapping rio's block conversation ⇄ OpenAI Chat
Completions (system-as-a-message, `tool_calls` with **string** `arguments`, `role:"tool"`
results, index-accumulated streaming tool calls, `finish_reason`). tcllib's json decodes a JSON
`null` to the string `"null"`, so the SSE reader treats `"null"` as absent (documented in the
core) — OpenAI streams `content:null` on tool/role chunks.

**Three contract-hardening changes the second provider forced:**
1. **Per-provider keys.** `rio::agent` held a single `keyed_provider` slot — a second keyed
   provider could not coexist. Replaced with per-provider key state: `agent.key.set/clear`
   take a provider name (the GUI always sends it), and Claude's and ChatGPT's keys are
   independent 0600 stores. This was *required*, not optional — two keyed providers is the
   whole point.
2. **Provider metadata in the registry.** `register_provider` gained `-label` and `-signup`, so
   a provider *declares* its display name and where-to-get-a-key hint. A new shaped op
   **`agent.providers`** → `[{name,label,keyed,key_set,signup}]` lets the GUI render its picker
   and a **generic** key dialog from data rather than hardcoding "Claude". The GUI's provider
   radios + key items are now cascades filled from the core (like `.m.view.theme`), so a new
   provider appears with no GUI change.
3. **Shared plugin lib** ([plugins/lib/](plugins/lib/), `rio::llm::*`). The HTTPS streaming
   transport and the ASCII-safe JSON serialisers were provider-agnostic and were duplicated the
   moment a second plugin existed; extracted to one copy both plugins source (guarded against a
   double load, since the core sources each plugin).

**Milestone B (explicit successor to D19), NOT built here:** make `provider` an installable
`kind` in the **same** D39 repositories — one infrastructure, a publisher adds `kind: provider`
to a manifest — loaded core-side behind a versioned `provider-api` and a consent/trust gate.
C was sequenced first precisely so the contract above is proven by a second in-tree
implementation before it is frozen for outsiders. This keeps the promise that people contribute
providers through one repo, with no second infrastructure. *(Since realized — D66.)*

---

### D66 — `provider` becomes an installable D39 kind; OpenAI ships as the first one

D65's milestone B, delivered. A `provider` is now an installable `kind` in the *same* D39
repositories (D39) — a publisher adds `kind = provider` to a `rio-extension.conf` and ships the
Tcl beside it; no second distribution infrastructure. To dogfood the path rather than only
speccing it, the in-tree OpenAI provider was **extracted** out of the core and now installs as
that first `kind = provider` extension ([extensions/openai/](extensions/openai/)); the built-in
set is back to **echo + Claude** (Claude stays in-tree as the sanctioned, always-present path).

**Why a provider is the highest-trust kind, and how that shaped every choice.** The D39 kinds
that shipped before load into the *GUI* (syntax/mode are drop-in Tcl, D32/D38) or are pure data
(theme, D24). A provider is executable Tcl that loads into the **core** (which may be a remote or
shared host, D30) and can be handed the user's **API key** (D21) to make **network calls** with
it. So, unlike the others:

- **It installs CORE-side**, through new `provider.*` ops ([ops-provider.tcl](rio-core/ops-provider.tcl),
  [provider.tcl](rio-core/provider.tcl)) that mirror `theme.put/list/delete` (D39): the code is
  the core's, so it lands on the core's disk (`$XDG_DATA_HOME/rio/providers/<name>/`), and a
  remote core stores on its own. The GUI's Extensions window routes a `provider` install to
  `provider.put` exactly as it routes a `theme` to `theme.put`.
- **It activates on restart, never live.** `provider.put` writes the store but does **not**
  `source` the code; the core sources every installed, version-supported provider once at startup
  (`rio::provider::load_all` in [server.tcl](rio-core/server.tcl)). This was a deliberate choice
  over live-loading (which syntax/mode do GUI-side): sourcing freshly-fetched remote Tcl into a
  long-lived, possibly shared, already-running core is a bigger trust surface than a deliberate
  restart. The GUI says so on install.
- **It is gated by a VERSIONED contract, `provider-api`.** This is the point of doing C first —
  the seam C hardened (register_provider with `-label`/`-signup`/`-key`, the
  `{conversation tools system post}` proc + the `delta/tool/done/error` post vocab, and the
  runtime helpers `rio::llm::*` + `rio::secret::*`) is now **`provider-api = 1`**, loaded before
  any provider is sourced so an installed one ships no copy of it. A manifest declares the version
  it targets; the core refuses to install one past what it implements and lists-but-skips a
  too-new one already on disk (a store populated by a newer rio, then read by an older) — D39's
  "too-new lists, doesn't install", now for executable code. `provider.list` reports the core's
  `api_max` so the GUI greys such a row before an install is even attempted.
- **Its consent is bespoke.** The D39 install dialog names code-vs-data; a `provider` adds the
  real escalation in plain words — runs in the core (maybe remote/shared), can receive the key you
  enter for it, makes network calls with it; install only from a source you trust with your model
  credentials.

No provider registry, index, or account is added — a provider is one more line in a
`sources.list` repo, chosen and installed like any extension, with the credential trust made
explicit at the one moment it matters. Local OpenAI-compatible servers (Ollama, llama-server) ride
the same installed extension by pointing its `messages_url` at localhost (D8/D65).

---

### D67 — "Extensions…" moves from the View menu to Settings

A small placement fix. D39 put the Extensions window under *View* as "rio's first D35-style tool
window, to be re-hosted into a dock when D35 lands" — forward-looking, but D35 hasn't landed and
the item is a **management modal**, not a pane toggle. Its View neighbours are pane toggles
(Files/Git/Agent/Search) and view preferences (Wrap, Line Numbers); it fit none of them. *Settings*
already holds the **choosers Extensions feeds** — Agent Provider (D65) and Editing Mode (D38) — and
its two peer management dialogs, **Preferences…** (D58) and **Keyboard Shortcuts…** (D23).
Extensions… sits **directly under Preferences…**: the two read as the pair of "customize rio"
windows — Preferences the built-in settings, Extensions the installer for the providers / modes /
themes / syntax those settings pick from. The Preferences window **mirrors** this with its own
*Extensions…* button (bottom-left, beside Close), so the pairing holds whichever door you came in
by. View ends on its Theme cascade; the move also shortens View, serving D64 (keep the View menu
within screen height). `smoke.tcl` guards assert Extensions… is in Settings (not View) and that the
Preferences window carries the button, so neither can silently drift. (The window itself, the D39
install machinery, and the D66 provider path are unchanged — only the entry points moved.)

---

### D68 — Static help must look different from interactive controls

A standing UI rule, made explicit after the Repositories dialog tripped it: a window's inline
help/description text and its interactive elements (list rows, entries, buttons) must be
distinguishable at a glance — the user should never guess what is clickable/editable/selectable vs.
what is just explanation. The Repositories dialog had a hint sentence in the normal `ui.fg` sitting
directly above a **borderless** listbox whose one repository URL rendered in the *same* `ui.fg`, so
the selectable/removable entry read as another line of help. Two levers, used together:
**(1) help/description/hint text in a muted secondary role** (`gutter.fg`), never the `ui.fg`
interactive text uses; **(2) interactive containers carry a visible boundary** (`-relief solid
-borderwidth 1`, as the Preferences category list already does), not a borderless widget on the
window's own background. The general bar — a control that does nothing when clicked, or static text
a user tries to click, both erode trust — so every new dialog is scanned for help sharing a look
with controls before it ships.

---

### D69 — Claude too becomes an installable provider; `echo` is the only built-in

D66 extracted OpenAI but kept **Claude in-tree** as "the sanctioned, always-present path." That
asymmetry is now gone: Claude installs as a `kind = provider` extension
([extensions/claude/](extensions/claude/)) exactly like OpenAI, and the core ships **only `echo`**
built-in. A fresh core boots with the offline echo stub and nothing else; a real agent — Claude,
OpenAI/ChatGPT, or a later one — is **installed** from the D39 repositories like any extension
(restart-to-activate, D66). This includes rio's own dogfooding core: a clean checkout installs
Claude once from the repo.

**Why reverse D66's choice.** The seam D65/D66 hardened (`provider-api = 1`) exists precisely so a
provider needn't live in the tree; keeping one provider in and one out only muddied that. Providers
track fast-moving vendor APIs — they are exactly the thing that should **not** be welded into the
core. rio-core and rio-gui own the *interface* to plug a provider in; the providers are peers on the
far side of it. One infrastructure now serves all of them: install, version-gate, key-entry, and the
`{conversation tools system post}` contract are identical whether the backend is Claude or ChatGPT.

**What moved, mechanically.** `git mv plugins/claude → extensions/claude`; the loader
([claude.tcl](extensions/claude/claude.tcl)) now sources only its two payload files
(`inference.tcl` + `api-face.tcl`), the runtime coming from the core (as OpenAI's does); a
`kind = provider` manifest ([rio-extension.conf](extensions/claude/rio-extension.conf)) and an
`extensions/index` entry were added; the unit tests source the shared lib at the extension depth
(`.. .. .. plugins lib json.tcl`). [server.tcl](rio-core/server.tcl) no longer sources any provider
from the tree — `rio::provider::load_all` sources every installed one after the runtime.
**`plugins/lib/` stays put**: it is the frozen `provider-api = 1` runtime home that server.tcl and
every provider's tests reference, not a provider payload.

---

### D70 — A well-defined place for the user's system and project prompts

D34 gave the core a provider-agnostic system prompt (a shipped base + an optional
per-project `.rio/agent.md`) but no way to *reach* it: the files were undocumented and
had no UI, and there was no home for a user's own standing instructions that wasn't
"replace rio's shipped tool contract." D70 closes that, staying deliberately small — two
user prompts, obvious places, clear in both the UI and the docs, and **provider-agnostic**:
the same instructions shape a turn whether the backend is Claude, ChatGPT, or a later one
(the composed string is the provider contract's `system` argument, D26/D65).

**Three layers, composed base → system → project** ([agent-prompt.tcl](rio-core/agent-prompt.tcl)):

- **base** — rio's shipped `agent/prompt.md` (its tool contract + coding craft): rio's own
  machinery, not a user knob. Advanced users may still swap it wholesale via an XDG copy.
- **system** *(new)* — the user's `system.md` in the XDG agent dir: their standing
  instructions for **every** project, **ADDED on top of** the base, never replacing it.
  jka chose the additive layer over reusing the base override precisely so a user can't
  accidentally delete rio's contract while writing their own prompt.
- **project** — the existing `.rio/agent.md` at the open project root: instructions for
  **this** codebase, appended last.

Each layer is plain Markdown **loaded as data, never executed**; any may be empty, and an
empty file contributes nothing.

**Surfaced without welding UI to paths.** A new core op **`agent.prompt.edit {which}`**
([ops-agent.tcl](rio-core/ops-agent.tcl)) resolves the `system`/`project` file, **creates
it empty if absent** (`ensure`), and returns its path; `project` with no open project is a
`bad_request`. The GUI's **Agent Prompts…** dialog (reached from Preferences ▸ Agent; see D85)
([rio-gui.tcl](rio-gui/rio-gui.tcl)) calls it and opens the file in **rio's own editor**
(`do_open`) rather than building a bespoke text widget — so editing is the normal edit
path, and because the **core** owns and creates the file, a **remote** core resolves it on
its own disk (D30) and the tab title shows the real location. The dialog's static help is
muted (`gutter.fg`) with the buttons the only controls (D68); the project button is
disabled with a hint when no project is open. The starter file is **empty on purpose** —
the teaching lives in the dialog and the docs (jka: "the docs and UI should make clear
where is what"), not in seeded template text that would otherwise leak into the prompt.

### D71 — Relative line numbers (gutter modifier)

The line-number gutter (D49) gains an optional **relative** mode: every line but the
caret's shows its **distance** from the caret line rather than its absolute number, so a
`3j` / `5k` motion count is read straight off the gutter. **Off by default;** a toggle
sits with the other display switches in **View ▸ Relative Line Numbers** and the
Preferences View category (one global `::relative_line_numbers`, one applier
`apply_relnum` — the two-door pattern of D58/D60, so menu and window stay in sync).

It is a **hybrid** (vim's `number` + `relativenumber`): the caret's own line keeps its
**absolute** number as a where-am-I anchor, every other line its unsigned distance. It is
a **modifier on the shown gutter** — `gutter_redraw` returns early when the gutter is
hidden — not a third gutter state, so it composes with the on/off of D49 and needs no new
width logic: the gutter stays sized to the absolute last-line digit count, so toggling
relative (or moving the caret) never reflows it.

Relative numbers must **follow the caret**, so the repaint rides the same caret-move seam
D60 built: `curline_update` (called from `cursor_moved`, `refresh_status`, and the
search-jump) schedules an idle-coalesced `gutter_redraw` whenever the mode is on. The one
piece of real logic — the number a row shows — is factored into a **pure** `gutter_label
{ln caret relative}` helper so it unit-tests headless, where the *painted* glyphs cannot
(`dlineinfo` needs a mapped window — the D49 gutter-smoke limitation).

---

### D72 — The anonymous (no-project) workspace

D31 resumes a working space **per project root**, keyed by `rio::project::root`; with **no
project open** the `workspace.*` ops were a deliberate no-op. That left a real workflow
unremembered: a **loose "daily workspace"** — one always-open rio with many tabs for notes
and quick edits, whose files **span folders and share no root**. A bare `rio-gui` launch
came back with view state (layout/panes) but none of those files.

rio already treats **"no project open"** as first-class (the scratch buffer, files opened
by absolute path). So the fix is small: the **empty root selects an anonymous session** —
one reserved store file (`sessions/anonymous.json`, a literal name that can't collide with
a real root's 32-hex md5 key) — instead of a no-op. `workspace.save`/`get` now honor an
empty root, and the store's `save` keeps the self-describing `root` field empty rather than
normalizing `""` into the cwd. **Core-only change:** the GUI already calls `session_save`
on every tab change and quit, and `session_restore` at boot, **unconditionally** — they
only came up empty because the ops refused to key without a project.

**Still core-owned, like D31.** The anonymous session's files live on the core's
filesystem (local or remote), so it follows a remote core exactly as a project session
does — a no-project session resumes over the wire too. **Honest caveat:** there is a
*single* anonymous session, so two simultaneous no-project instances clobber each other's
(fine for the one-daily-instance workflow this serves; project sessions stay isolated by
root) — logged in [CAVEATS.md](CAVEATS.md). A separable future complement — **remember the last project *folder* and reopen it
on launch** (a `last_project` pointer in `prefs.json` + a boot-time reopen) — would cover
the project-folder workflow; deliberately left out here to keep this to the loose-files
case.

### D73 — Compare is its own top-level menu

The diff view (D28) — **Compare With File…** and **Close Compare** — had lived under **View
▸ Editor Layout**, next to Split / Unsplit / Move Tab. That grouping conflated two different
things: **Editor Layout** arranges the editing *groups* (how the open buffers tile), whereas
Compare is a distinct **mode** that swaps the whole editor surface for two read-only diff
panes. Reading "Compare" as a *layout* of the editor was the confusion; it never was one.

So Compare moves to its own **top-level `Compare` menu**, sitting after **View** in the
menubar (File · Edit · View · **Compare** · Tabs · Settings). It holds the two commands and
nothing else — a two-item menu is justified because the mode is otherwise only reachable by
the agent's automatic "opened in compare view" flow (D28) or a picked-file dialog; a named
top-level door makes it discoverable and gives that flow a home the user can point at. This
keeps **Editor Layout** honestly about group layout, and doesn't lengthen **View** (the D64
height budget is unaffected — Compare left the submenu, it didn't join the top level of
View). Pure GUI/menu change; the `compare_*` procs and the `Esc` accelerator are untouched.

### D74 — Compare against an open tab; a shared buffer picker; the Tabs menu retired

Two gaps closed by one small component. **(1)** Compare could only diff the active buffer
against a **file on disk** (D28's `compare_with_file_dialog`), but the more frequent case is
comparing it against **another already-open tab** (two notes, a file and its variant). **(2)**
The top-level **Tabs** menu (D57) was a `-postcommand` cascade of every open buffer — the one
menu with no size bound, able to grow screen-tall on X11 (the standing menu-overflow caveat),
and it showed only basenames, so two same-named tabs were indistinguishable.

Both are "**pick an open buffer from a list**", so both use one **modal picker dialog**
(`buffer_pick_dialog`, modelled on `remote_browse_dialog`: themed toplevel, listbox +
auto-hiding scrollbar, Double-click/Return choose, Escape/Cancel, `grab` + `tkwait`). The
row list is built by a separate `buffer_pick_rows {exclude}` — walking `$::groups`/`gorder`
(the same source the old `tabs_menu_fill` used), each row `{id label}` with the tab name, the
unsaved ●, and the **parent directory as a hint** so duplicates are told apart. Splitting the
list-build from the modal keeps it headless-testable, exactly as the cascade's `-postcommand`
was directly callable.

- **Compare menu** now leads with **Compare With Another Tab…** (`compare_with_tab_dialog` →
  `buffer_pick_dialog` excluding `$::cur` → `compare_with_tab`, both sides live `buffer.text`
  so unsaved edits show), then **Compare With A File…**, then Close Compare. Tab first: it is
  the more frequent case.
- **Tabs menu retired.** The top-level cascade and `tabs_menu_fill` are gone; reaching a tab
  by name is now **View ▸ Switch to Tab…** (`switch_tab_dialog` → `buffer_pick_dialog` →
  `activate`), a **bounded** dialog that can't outgrow the screen and shows paths. The menubar
  trims to File · Edit · View · Compare · Settings.

**Caveat retired, partly.** The bounded dialog removes **Tabs** from the pair of unbounded
data-driven menus in [CAVEATS.md](CAVEATS.md); only the **Theme** cascade remains there. No
new keyboard shortcut for Switch to Tab… (menu + dialog only) — a `goto-tab` chord is a
possible later add. Pure GUI change; no core op touched. The **Multi-Line Tabs** view
preference (D57) stays in the View menu — it was never part of the navigation list.

### D75 — A top-level Find menu

The search cluster added in D36 — **Find…**, **Replace…**, **Find Next**, **Find Previous**
— plus the project-wide **Search…** (D-around-36, relabelled) lived behind a separator at the
bottom of the **Edit** menu. That grouping was fine but crowded Edit, and the cluster is
coherent enough to stand on its own: it now becomes a top-level **Find** menu, placed left of
Compare (both are editor-action menus to the right of View). Edit is left as the classic
clipboard/selection ops (Undo/Redo, Cut/Copy/Paste/Select All) — the Win98 canon.

- **Named "Find", not "Search",** deliberately: rio already has a **Search** *pane* toggle in
  View (D-around-36) and a `Search…` command for project-wide search; a top-level *Search*
  menu would read as the same thing as that pane. **Find** disambiguates, four of the five
  items are Find anyway, and the lone `Search…` sits below a separator as the "widen to the
  whole project" escalation (the Sublime *Find ▸ Find in Files* shape).
- **Whole cluster or nothing.** Moving the *entire* group (not splitting Find between two
  menus) is what keeps it intuitive; a half-measure that left some find items in Edit would be
  worse than either end state. The cost — departing from the *Find-under-Edit* convention of
  Windows/VSCode/Notepad — is mild and has direct precedent in **Sublime Text**'s top-level
  Find menu.

Menubar is now **File · Edit · View · Find · Compare · Settings**. Items keep their labels,
commands, and accelerators; the keymap-refresh block's `entryconfigure` paths move from
`.m.edit` to `.m.find`. Pure GUI/menu change; the find engine (core, D36) is untouched.

### D76 — A Help menu with About rio (build identity)

rio has no release version yet — **RELEASING.md Gate 2** is where a `v0.1.0-alpha` git tag
will come from, "so a tester can say exactly which rio they're running". Until then a tester
still needs to name their build, so a **Help** menu (last/rightmost, the Windows/VSCode
convention) gets an **About rio** modal that shows the identity we *do* have: the **short
commit** of the checkout.

- **Where the id comes from.** `git describe --tags --always`, run against rio's **own**
  source dir (`[file dirname $::rio_self]`, the normalized script path) — deliberately not the
  user's project, and not the core (which may be a different build on another machine, or
  remote). `--always` yields the abbreviated commit today; the moment Gate 2 tags a release,
  the *tag* shows instead — About upgrades itself for free. A git-less install falls back to
  `"unknown"`. Computed once and cached (`::rio_build`): About is rare, so nothing shells out
  at startup. This is the GUI shelling out to git directly — the one place that's right, since
  it's a fact about the local install, unlike the core-owned `git.*` project ops (D7). A
  companion `rio_build_date` reads that commit's **committer date** (`git show -s --format=%cd
  --date=format:…`, local zone → `YYYY-MM-DD HH:MM`) the same way — same source dir, same
  `"unknown"` fallback and caching — so a tester can name *when* the build was cut, not just
  which commit.
- **The modal.** A small themed toplevel: the name, a one-line description, and a dim
  two-column facts block — **Build** (the id), **Date** (its commit date), and **Protocol**
  (`::rio_protocol`, handy in a bug report). Static text is muted labels (blended fg→bg, since
  the theme has no `ui.mute` role); the lone control is Close; Esc/Return dismiss. Non-blocking
  (grab, no `tkwait`) — it only informs.

Menubar is now **File · Edit · View · Find · Compare · Settings · Help**. Pure GUI change; no
core op, no new theme role.

---

### D77 — Open several files at once (native chooser multi-select)

The **Open file** dialog (`open_dialog`) picked exactly one file: `tk_getOpenFile` defaults to
single-select, so Ctrl/Shift-clicking extra files in the native chooser did nothing on Linux
and Windows (reported by jka). The fix is one flag: **`-multiple 1`**, which lets the native
chooser select several files and turns the result into a **list** of paths (empty on cancel).
`open_dialog` now loops it, `do_open`-ing each — and since `do_open` already dedups against
open buffers and activates, opening N files leaves the last one focused, exactly as opening
them one by one would.

- **Local branch only.** Multi-select applies to the native chooser, i.e. the **non-remote**
  branch. The remote path stays `remote_browse_dialog` (a single-select `fs.list` tree, D29) —
  one pick at a time; extending it to multi-select is a separate, later concern. The two
  branches are now split cleanly (each opens its own picks) instead of sharing a tail.
- **Test.** smoke.tcl stubs `tk_getOpenFile` to hand back two paths and asserts both open with
  the last active. The stub must force `::core_remote 0`: the test core is reached over a
  socket, so it's *remote* by default, and the remote branch is a modal `tkwait` that hangs
  headless — the multi-select code lives on the native-chooser branch, which is what we mean
  to cover.

Pure GUI change; no core op.

---

### D78 — Multi-line tabs flow into packed row-frames (not a grid)

The **Multi-Line Tabs** mode (D57's `multi`, `::tab_layout`) laid its rows out with `grid`
(`-row/-column`), which on Linux and Windows looked wrong two ways (reported by jka): rows
didn't **huddle** — a short tab left a gap because grid forces **uniform column widths
across all rows**, stretching it to match a longer tab in the same column index — and the
**rightmost tab of a row clipped** past the strip edge, because grid's stretched columns
made the real row wider than the `tab_pixwidth` accumulator that decided where to wrap.

Both are the same root cause, so one fix: `tabstrip_layout`'s `multi` branch now flows the
handles into **one packed row-frame per visual row** (`tabstrip_row` builds each `r<n>`
container, `pack -in` places the handles left-to-right). `pack` honours each tab's natural
width — tight per-row huddling, no column stretching — and a new row opens *before* a tab
would overrun `avail`, so nothing clips. `pack -in` manages geometry without reparenting
(the handle stays a child of the strip), so `tabstrip_layout` freely destroys the stale
`r<n>` frames each pass — including on a `multi`→`scroll` switch, so no empty rows linger.

**The `-in` z-order trap.** Because `-in` doesn't reparent, the handles remain *siblings*
of the row-frames, and a frame created *after* them stacks on top — its background then
paints over the tabs, an **empty bar** (a first cut shipped exactly this). `tabstrip_row`
therefore `lower`s each frame beneath the handles. Guarded in tabs.tcl: `winfo children`
lists siblings bottom-of-stack first, so every `r<n>` frame must sort before every `b<id>`
handle — an assertion that fails on the un-lowered version.

**Justified rows.** Natural-width tabs left a ragged gap on the right of each row (jka
asked for it filled). The layout is now two passes: pass 1 assigns tabs to rows, pass 2
places them **justified like a paragraph** — every row *but the last* packs its tabs
`-expand 1 -fill x`, so pack spreads the leftover pixels equally and the row fills the
strip width; the last row stays natural/left-aligned (a justified paragraph's last line
isn't stretched). A single-row layout is therefore just that ragged last line. Within a
widened tab the name stays left and the `×` right. tabs.tcl asserts a non-last row's tab
carries `-expand 1 -fill x` and the last row's does not.

`scroll` mode, the `◂ ▸` overflow arrows, `tab_pixwidth` (still analytic, so the layout
stays synchronous and headless-testable), and `refresh_tabs` are unchanged. Pure GUI
change; no core op. tabs.tcl now asserts the row-frame structure instead of grid rows.

---

### D79 — Per-provider agent prompts (a fourth system-prompt layer)

D34 made the agent's system prompt a **core-owned, provider-agnostic** string; D70 gave the
user two layers to fill — `system.md` (their standing instructions for **every** project) and
`.rio/agent.md` (this **project**). jka asked for a third user axis: instructions scoped to a
**single provider** — Claude-only formatting quirks, or house rules for a local
OpenAI-compatible model — "besides the general and project-based scope," while keeping this a
core concern the providers merely respect.

**Decision.** Add a fourth compose layer, `providers/<name>.md` in the XDG agent dir
(`$XDG_CONFIG_HOME/rio/agent/providers/claude.md`, `…/openai.md`), read **only when that
provider is the active one**. Compose order is now **base → system → provider → project**: the
project's own conventions are the tightest, most task-specific context, so they stay last
(most-refining); the provider layer ("how to talk to *this* model") sits just above it.

**The contract does not change — the provider stays blind to the layer.** `rio::agent::prompt::compose`
now takes the active provider's *name* (the loop passes `rio::agent::provider_name`); it folds the
matching file into the **one** `system` string the provider already receives. A provider never
learns a per-provider layer exists — it just gets more text — so nothing in the provider API,
the extensions, or `provider.put` moves. `echo` contributes none (it ignores `system`
entirely), and an empty/unknown name or a missing file simply adds nothing (safe degrade, as
every prompt layer does). The filename is guarded to `[A-Za-z0-9_-]+` (a registered provider's
name shape) so `providers/<name>.md` can't be steered outside the dir.

**Op.** `agent.prompt.edit` gains `which = provider` with a required `name`, validated against
the live registry (`rio::agent::provider_names`) and refusing `echo`; `system`/`project` behave
exactly as before. The core still owns and creates the file (a remote core on its **own** disk,
D30), so the frontend only opens the returned path.

**GUI.** Rather than a new consolidated window, jka chose to **grow the existing Agent Prompts…
dialog** (D70): it now has a third row — a provider chooser (every registered provider *except*
echo) plus an "Edit its prompt…" button — while the provider picker, per-provider API key, and
the auto-accept / compare-complex toggles stay where they are in Preferences ▸ Agent. When only
`echo` is present the row is disabled with a hint (a provider prompt needs a provider to attach
to). Static help stays muted (D68); the chooser and buttons are the only controls.

*Follow-up (same feature):* the **Preferences ▸ Agent pane** was reading as a stub — with no
provider installed it was just the `echo` radio and two toggles, and it had no door to the
prompt work at all. Two additions, both by existing patterns: an **Agent Prompts…** button
(the reach-not-reimplement pattern of the Keyboard pane's shortcuts button — at the time a
"second door" beside the Settings menu's; **D85** later made the Preferences pane the *only*
door), and a **muted `echo`-only hint**
(`prefs_hint`, gutter.fg) pointing at Extensions… — shown only while no real provider is
installed, since the pane is self-explanatory once one is. The provider radios / keys / toggles
are unchanged.

**Scope.** User-global per provider (all projects). A project×provider layer
(`.rio/agent/providers/<name>.md`) is deliberately **not** built — a later axis if it's ever
wanted. rio without the agent is untouched: this is one more opt-in file that defaults to empty.

---

### D80 — Git: discard changes (everyday "undo my edits" for normal people)

rio's git write-ops were stage / unstage / commit (D44/D45). The missing everyday verb was
**discard** — "throw away my changes to this file." jka asked to aim it at *basic-to-mediocre git
for normal people*: one safe, obvious, confirm-gated action per changed file, worded so a
non-expert isn't surprised.

**One concept:** *make this file match the last commit; if it isn't in the last commit, remove it.*
Realised in `rio::git::discard {cwd path}` (git.tcl), keyed off the path's own porcelain staged
char X:

- **tracked change** (M/D/…): `git restore --staged --worktree -- <path>` — revert to HEAD,
  dropping **both** the staged and the worktree edit. This is the intuitive "undo everything I did
  to this file," not just the unstaged half.
- **new file** — untracked (`?`) or a staged addition (`A`): **remove** it (`git clean -fd`; for a
  staged add, `git reset` first so it's untracked, then clean). A never-committed file has nothing
  to revert *to*, so discarding it means it's gone.
- no changes → `bad_request`.

**Why `restore` is safe here when D44's unstage deliberately used `reset`:** the restore branch only
runs for a file with a committed baseline, so HEAD always exists there; the unborn-HEAD case (no
commits) is only `?`/`A`, handled by the remove branch. So the `restore --staged` HEAD-resolution
problem that pushed unstage to `reset` can't arise.

**Op + GUI.** `git.discard {path ?cwd?} -> {action revert|remove}` (ops-git.tcl), mirroring
add/unstage/commit. The git-pane row menu (`git_menu_build`) gains a separated, destructive entry
worded for the state — **"Discard Changes…"** for a tracked change, **"Delete…"** for a new file —
behind a No-defaulted `tk_messageBox` confirm (`git_discard_confirm`, mirroring the D48 file-delete
gate); on success the pane repaints and the header flashes the outcome. The core decides the actual
action and returns it, so the GUI's wording and the real effect can't drift.

**Scope.** Git-pane menu only for now; the file-tree row menu is an easy follow-on (tracked rows —
its fs "Delete…" already removes untracked files). Rename-aware discard and a "Discard all" bulk
action are noted, not built. Tests: git.test drives real-git discard for every state
(revert/remove/unstage+revert/clean-path bad_request); smoke asserts the menu offers the right entry
per state.

---

### D81 — Multi-line commit message body

D45's commit bar took a single **summary** line — fine for the common case, but git commits have a
subject **and** an optional body (a blank line then prose), which normal users reach for on a
meatier change. Added the body as an **opt-in expansion of the same bar**, not a second surface.

**Shape.** A small **`＋` toggle** on the bar reveals a multi-line description `text` widget below
the summary (`−` collapses it); it starts collapsed, so the one-line case is untouched — the same
"appears only when needed" restraint the bar itself follows (D36). `git_commit` joins them as
`summary\n\nbody` — git's own subject/blank/body convention, which `git commit -m` records verbatim,
so **the core op is unchanged** (`git.commit` still takes one `message`). An empty body adds nothing;
an empty summary is still refused. The body carries its own greyed placeholder (the same
placed-child-label device as the summary hint, so it never pollutes `.body get`).

**Keys.** Enter in the one-line summary still commits; in the multi-line body Enter inserts a
newline, so **Ctrl+Enter** is the commit chord there (and works from the summary too, for muscle
memory). `git_commit_body_set` re-packs the bar deterministically each toggle (body bottom, then
Commit + `＋` right, summary filling left) and is reused to re-collapse + clear after a commit or
when the bar auto-hides. Pure GUI; smoke asserts the toggle reveals/collapses the body and that a
real subject+body is recorded through the core.

---

### D82 — Agent "working" indicator (retro-productivity busy animation)

Sending a turn to a real LLM has a multi-second gap before the first token streams (and again
after each tool round-trip); the agent pane showed nothing there and looked frozen. jka wanted
the familiar "working…" affordance (the VSCode-plugin feel) done the rio way — pure Tk, no deps —
and, for character, cycling **90s/2000s productivity-software loading phrases** ("Reticulating
splines…", "Defragmenting…") rather than the modern "elaborating/actioning" vocabulary.

**Implementation.** A small busy state machine (`chat_busy_start`/`tick`/`render`/`stop`) drives
the existing **`.chat.status`** strip via an `after` loop — no new widget. `render` paints the
current phrase with a 1→2→3 dot cycle (**ASCII periods only**, so no UI font can drop a glyph —
the D54 Windows/Alpine/OpenBSD matrix); the phrase re-rolls from `::chat_busy_words` (an in-file
list, data — no download) every ~2.4 s. `chat_status_update` is guarded to no-op while busy, so a
provider/mode change can't clobber the animation; `stop` hands the strip back to "Provider · mode".

**Lifecycle.** Start in `chat_send` on a good ack; stop on `agent.message`/`agent.error`; **pause**
on an `agent.propose` that raises the approval bar (now waiting on the *user*, not the model — but
under auto-accept it keeps running); restart in `agent_decide` (the turn resumes); stop in
`chat_clear`. Entirely GUI chrome over events that already flow — **no core change**. smoke covers
it deterministically (start/stop flags, the pure render at fixed frames, each lifecycle event, and
a real echo turn flipping it on then off). Noted, not built: a leading ASCII spinner, a
per-provider prefix, and turning ▶ into a Stop button (no per-turn cancel op yet).

---

### D83 — Agent run-command tool (gated, async, timeout-bounded)

The last deferred piece of the agent's tool surface (O4): letting it **run commands** — tests, a
linter, a build, git. D53 already settled the philosophy (the line is *autonomy*, not capability):
a command is in scope **because a human approves it**. So run-command lands as a new tool behind
the *same* propose/approve gate the write slice uses (D26 s5), with the guardrails its danger
warrants. **No provider plugin changed** — the gate is core, provider-agnostic (proof: the Claude
suite is untouched).

**Always gated — the one place auto-accept doesn't reach.** A write can be auto-applied
(*Auto-accept edits*); a command **never** is. Running arbitrary argv is the most dangerous
surface, so the core's `_do_exec` yields for approval unconditionally (it doesn't consult
`auto_accept`), and the GUI raises the bar regardless of the toggle. jka's call: the toggle stays
scoped to edits, and no second "auto-run commands" toggle was added — a human always sees the exact
command first.

**Async, because a timeout demands it.** `exec.run` blocks the whole single-threaded core to
completion — fine for git's short reads, but the agent may run anything, and an `after`-based
timeout can't fire while the interpreter sits blocked in `exec`. So command execution is
**asynchronous**: a new `rio::exec::start {argv cwd stdin timeout_ms donecmd}` spawns the child,
returns at once, reads stdout off a pipe as it arrives (stderr to a temp file, exit code from
`close`'s `-errorcode` — same mapping as `run`), and fires `donecmd` on completion; `_do_exec`
yields until then. The core stays responsive while a command runs (a real win for the
remote/multi-frontend architecture, not just timeout plumbing). `run` is untouched — git keeps it.

**Bounded timeout (jka's call).** Every command is time-boxed — default **120 s**, max **600 s**,
no "unlimited" (there's no per-command cancel op yet, so the timeout is the safety net). A watchdog
`after` kills an overrunning child (`kill -TERM` on unix, `taskkill /F /T` on Windows — log any
Windows quirk in [CAVEATS.md](CAVEATS.md)) and reports it as `timed out` (an `is_error`
tool_result, so the model knows it didn't complete). `reset`/`_seal_dangling` cancel an in-flight
command (kill + drop the coroutine) so a mid-run reset leaks no process.

**Confinement = approval + argv discipline (no allow-list).** Per D53 the gate is approval, **not**
a ban, so there's deliberately no command allow-list. *(D84 later adds an **opt-in**, human-authored
allow-list — standing approval, still human-in-the-loop; it changes only whether the bar appears,
never these rails.)* The rails are: **argv-only, no shell** (the
tool description drills this into the model — no pipes/redirects/globs/`&&`); **cwd confined to the
project root** (reuses `_confine`); and `prepare_exec` **refuses any argv element Tcl's `exec` would
read as a redirection or pipe** (`<`, `>`, `2>`, `|`, `&`, …) — closing the residual exec
redirection-token surface (noted deferred in [exec.tcl](rio-core/exec.tcl)) on the agent path, so a
model can't smuggle a `>` past the human by hiding it in the vector. A **non-zero exit is a
successful run** whose code is data (a failed test isn't a tool error); only a launch failure or a
timeout is `is_error`.

**Shape.** New tool `run_command`, `kind exec` (a third kind beside read/write); `is_gated` =
write∪exec drives both the mid-stream announce guard and the dispatch. The `agent.propose` event
gained a `kind` (edit|command); a command carries `command`/`display`/`cwd` (a project-relative
`cwddisp`, so a frontend needn't know the root) instead of a diff, and the GUI's `approve_bar` is
parameterized (prompt + the edit-only Compare button). Tested offline: the async primitive
(stdout, non-zero exit, separate stderr, timeout kill, cwd, launch failure, cancel-fires-no-
callback), `prepare_exec` validation (empty argv, redirection token, cwd escape, timeout clamp),
`format_exec` semantics, and the gated loop against a fake provider (approve/reject round-trips,
**still-gated-with-auto-accept-on**); GUI smoke covers the command bar, preview, and busy pause.
**Verified live** against **ChatGPT** on a remote core: a real turn had the model call
`run_command`, the gate raised `agent.propose` with the exact argv, approval ran it async, and the
model read `exit 0` + the stdout back — the provider-agnostic gate proven end to end with a real
model. **Remaining** (deferred, each a later add): **streaming** a command's output as it runs and
a per-command **Stop/cancel** (both want the D10 event-over-time model); output in its **own dock
panel** rather than inline.

---

### D84 — Agent command allow-list (standing approval)

D83 made `run_command` **always gated** — every command waits for a human. That is the right
*default*, but it re-asks even for the command you run twenty times an hour (`pytest`, `npm test`).
jka asked for what other agent frontends offer: mark a command **trusted** so it stops re-prompting
— "just like the pre-prompts thing" (the per-provider prompts of D79, persisted files in the XDG
agent dir).

**This refines D53/D83, it does not contradict them.** D53's line is **autonomy, not capability**:
the concern is a machine acting *unwatched*. A human-authored allow-list is **standing approval** —
a person decided, in advance, that `pytest` is fine — so it stays a human-in-the-loop act, not
cron/unattended autonomy ([[llm-integration-scope]]). The earlier "no allow-list" wording is
narrowed to: **no *silent* autonomy; a human authors every trust rule.** The allow-list skips
**only** the approval bar — an allowed command still passes the full `prepare_exec` gauntlet
(redirection guard, `_confine`d cwd, timeout clamp). Nothing else is loosened.

Decisions (jka): **default trust = the program** (`argv[0]` — trust every invocation, the "allow
`npm *`" mental model), with the **exact command line selectable** per click; and **three scopes
that mirror the system-prompt layers** (D79/D70) one-to-one — **global** (`allow.list` in the XDG
agent dir; every project), **per-provider** (`providers/<name>.allow.list` there; active only while
that provider runs, echo excluded), and **project** (`.rio/allow.list` at the project root). *(The
first cut shipped global-only; jka asked why the allow-list shouldn't layer exactly as the prompts
do — there was no reason, so it now does.)*

**Union semantics.** A command is trusted if **any currently-active layer** allows it: global
always; project when a folder is open; the active provider's layer when a provider runs. No
precedence — a match anywhere is enough — the allow-list analog of how the prompt layers all apply
together.

**Shape.** A rule is an **argv prefix** (a list of leading tokens); a command matches when its argv
*starts with* a rule's tokens (exact per-token compare — no shell, no globs). Core module
[`rio::agent::allow`](rio-core/agent-allow.tcl) resolves the three per-scope files (each one
Tcl-list rule per line, `#`/blank ignored, hand-editable) and unions the active ones in `matches`;
`rules`/`add`/`remove` take a `{scope name}`; an XDG test override covers global+provider, an open
temp project covers project. `_do_exec` consults `matches` and rides a new **`auto`** flag on
`agent.propose`: `auto 1` skips the approval yield and runs immediately (still async, still
registered for reset/seal); `auto 0` parks for the bar as before. Ops `agent.allow.list`/`.add`/
`.remove` grew optional `scope`/`name` (default `global`/active provider; provider validated as a
registered non-echo name, project needs an open folder). GUI: an `auto` command previews with **no
bar** and does not pause the busy indicator; a gated command's bar gains an **"Always allow ▾"**
menubutton whose two cascades (program first, exact second) each open a **scope submenu** (all
projects / this project / *provider* only), remembering the rule in the chosen scope *and* approving
the one in front of the user; an **Allowed commands…** manager (reached from Preferences ▸ Agent
after D85; originally the Settings menu) has a **scope selector** (mirroring the Agent Prompts
provider chooser) and lists that scope's rules with Add/Remove. *(Program-vs-exact and scope are per-click choices, not
persistent modes — deciding at the moment of trust beats a toggle you flip back and forth.)* Tested
offline: prefix-match, the **scope union** and each layer's isolation (a provider rule inert under a
different/echo provider; a project rule inert with no project open), add/remove/dedup + persistence,
the empty-rule guard, the scope-aware ops; the gated loop's **auto-runs-without-approval** and
**unmatched-still-parks** paths; GUI smoke covers the no-bar auto path and the cascade/scope-submenu
structure. **Verified live against ChatGPT** (remote core over the SSH-tunnel transport): with an
`echo` rule pre-added in the **global** scope, then in the **openai per-provider** scope, a real turn
had the model call `run_command`, the core raised `agent.propose` with **`auto 1`**, and the command
ran to `exit 0` with **zero approvals issued** — the standing-approval auto-run path proven end to end
for both scopes with a real provider. **Remaining** (deferred): a richer rules editor (regex, per-cwd,
session-only trust).

---

### D85 — Agent config lives in Preferences; the Settings menu keeps only fast switches

As the agent grew (D66 provider extensions, D26 keys, D70/D79 prompts, D84 allow-list) the
**Settings menu** had accreted a full column of agent items: an *Agent Provider* cascade, an
*Agent API Key* cascade, *Agent Prompts…*, *Agent: Allowed commands…*, and the two edit toggles.
jka's call: **choosing the provider from the top-level menu is right — it's a quick runtime switch,
"which model am I talking to right now" — but the other agent settings (keys, prompts, allow-list)
belong in the Preferences window.** The Preferences **Agent pane** (D58/D79) already carried all of
them as a "second door", so this makes that pane the **only** door and trims the menu.

**What stays in Settings ▸ :** the **Agent Provider** picker and the two frequently-flipped
checkbuttons — **Auto-accept edits** and **Compare complex edits** (jka kept these as quick
toggles). **What moved to Preferences ▸ Agent only:** the per-provider **API Key…** buttons, the
**Agent Prompts…** dialog, and the **Allowed commands…** manager. Nothing was reimplemented — the
same procs (`provider_key_dialog`, `agent_prompts_dialog`, `agent_allow_dialog`) are simply no
longer wired to menu entries; `providers_menu_fill` stopped filling the now-gone `.m.settings.keys`
cascade.

**Why:** a menu is for fast, low-ceremony switches; a settings *window* is where configuration
gathers and can grow (a scope selector, a key field, a multi-file prompt editor) without cramming
the menubar. One home also ends the two-door upkeep — the menu and pane could drift. This is the
same "don't let the top-level menus keep accreting" reasoning that created the Preferences window
(D58); D85 finishes the job for the agent cluster.

**Ripple:** user-facing strings that named the old path were corrected to **Preferences ▸ Agent** —
the provider extensions' `not_configured` / auth-error messages
([extensions/claude](extensions/claude/api-face.tcl), [extensions/openai](extensions/openai/api-face.tcl),
their `inference.tcl` HTTP-401/403 text) and the doc set (README/INSTALL/WINDOWS/ROADMAP/PITCH). The
`Settings ▸ Agent Provider` references stay (provider still lives there). Tests: `smoke.tcl` asserts
the *Agent Prompts…* entry is **gone** from Settings and the `not_configured` message now points at
Preferences; `prefs_window.tcl` asserts the pane carries both the prompts and allow buttons and that
the three moved items are absent from the Settings menu while the provider cascade remains.

### D86 — Drag a file onto the window to open it (OS file-drop, optional tkdnd)

Dragging a file from the OS file manager onto the rio-gui window now opens it — verified
missing on both local Windows and local Linux. The plumbing was already there: [`do_open`](rio-gui/rio-gui.tcl)
/ [`open_folder`](rio-gui/rio-gui.tcl) take a path, and the argv startup loop is the exact
"directory → `open_folder`, else `do_open`" dispatch. What was entirely absent was *receiving*
the drop — and that is the one thing **plain Tk cannot do**. OS drop reception lives only in
the external **tkdnd** extension (`<<Drop>>`, `tkdnd::drop_target`); there is no pure-Tcl path
(X11 XDND would mean hand-rolling the protocol; Windows needs an OLE C shim). Note this does
**not** contradict the "pure Tk, no tkdnd" choice for *internal tab dragging* (D-note above):
that gesture is press/motion/release inside our own widgets, which Tk handles natively — OS
file-drop is a different capability Tk genuinely lacks.

**tkdnd is taken as an OPTIONAL dependency** (jka, 2026-09-09): `set ::have_tkdnd [expr {![catch
{package require tkdnd}]}]`. Where it's installed, drag-to-open works; where it's absent,
rio-gui runs exactly as before, so the **hard** dependency bar stays Tk + json — tkdnd is a soft
enhancement, documented as optional in INSTALL/WINDOWS.

**Local core only.** A dropped path is a path on the *GUI's* machine, but the core performs the
`file.open`; with a remote core (`::core_remote`) that path is meaningless. So drop targets are
registered **only when `$::have_tkdnd && !$::core_remote`** — a remote user's drop is simply not
accepted (the native "no-drop" cursor), no confusing failure. tkdnd doesn't bubble a drop to
ancestors, so registration is in two places: the **toplevel `.`** (covers docks, the tab strip,
empty editor space) at startup, and **each group's text widget** in `make_editor_group` (drops
landing on buffer text). Both route to one handler, `dnd_open_files`, which runs the same
dir-vs-file dispatch and then raises the window (skipped under `RIO_GUI_HEADLESS`, where
deiconify would un-withdraw the test window). Tests drive `dnd_open_files` directly with a
synthetic path list — headless has no tkdnd and can't fire a real `<<Drop>>` — asserting a
dropped file opens as a buffer and the dir/file branch routes correctly (`smoke.tcl`); the
optional load means the whole suite runs unchanged with tkdnd absent (`$::have_tkdnd` is 0
there). Out of scope: uploading a dropped local file's bytes to a *remote* core (a separate
feature), and non-file (text/URI) drops.

### D87 — Files pane: an unfoldable tree from the project root

The Files pane was a **flat single-directory navigator**: it showed one directory, a `▴ ..`
row climbed to the parent, and double-clicking a folder *replaced* the view with that
folder's contents. You could only ever see one level. jka asked to **unfold directories in
place** — the VSCode / Win98-Explorer model — which was already the anticipated direction
(the expand/collapse twisty glyph was called out as *deferred* under the iconography sweep,
around the D-note at line ~1027, and ROADMAP's "Files pane — richer view" listed "an
expandable Explorer-style tree" as a candidate). This lands it.

**Decision: full tree from the project root.** The flat navigator is replaced by a tree
rooted at the open project root. Directories carry a `▸`/`▾` twisty; the twisty and the
gutter/indent left of the name are the **arrow**, and a **single click on the arrow** unfolds
the dir in place (its children drawn one indent step deeper right below it) or folds it. The
**name** is reserved for **double-click** (a dir toggles, a file opens); Return activates the
selected row too. A single click on the name just selects it; arrow keys move the selection
(all unchanged `rl_*` rich-list). The `..` row and the descend-replace navigation are **gone**
— you always view from the root and unfold only the branches you want. Folding keeps any
descendant expand-state, so re-opening a dir restores the sub-shape it had (VSCode behaviour).

**Click routing.** The single-vs-double, arrow-vs-name split is a files-pane concern, so it
overrides the plain `rl_*` click binds **only on the files body** (the git pane keeps
select-on-single-click). `nav_col_is_arrow {type depth col}` is the pure decision — a dir
row's name starts at char column `2 + 2·depth + 2` (gutter + indent + glyph + space), a click
left of that is the arrow — kept separate so it is unit-testable without pixels; `nav_b1` /
`nav_b1_double` map the pixel click to a row + column (`::nav_row_depth`, filled per paint)
and route it. Double-click on the arrow is a deliberate no-op (the first click already
toggled), so it can't fold-back a just-unfolded dir.

**State.** `::nav_dir` (which had meant "the shown dir") is renamed **`::nav_root`** — it is
now invariably the project root, set once on `project.opened`, never mutated by navigation.
A new **`::nav_expanded`** dict is used as a *set* of absolute dir paths currently unfolded;
it resets to empty on project open (a fresh project shows the collapsed root) and is **not
persisted** to the session (nav state never was — out of scope).

**Rendering.** `populate_nav` keeps the placeholder / header (now just the root's basename)
/ git-map setup, then calls the new recursive **`nav_render_level {dir depth git}`**, which
lists one directory via the same `fs.list` op, draws dirs-then-files (core-sorted), and
recurses into each unfolded subdir. `nav_render_row` gained a **`depth`** arg and inserts
`[string repeat "  " $depth]` between the fixed 2-char git-status gutter (flags stay column-
aligned across depths) and the type glyph. The git gutter (`nav_git_map` / `nav_dir_status`
rollup / `nav_file_status`) is untouched — `nav_dir_status` already rolled a change up from
*any* depth, so a folded folder still shows its `·`.

**Refresh scope.** The fs.changed / focus-return auto-refresh (D47) now repaints when the
change lands in a directory **currently on screen** — the root or an unfolded dir — via the
new `nav_dir_visible {d}` helper, replacing the old "== the one shown dir" test. A change
under a *folded* folder is correctly ignored until it's unfolded.

**File-management verbs (extends D48).** New File / New Folder now target the **clicked
row's own directory** (a dir row → inside it, and it **auto-unfolds** so the new entry shows;
a file row → alongside it; nothing selected → the root) rather than one global "shown dir",
and **Rename / Delete apply to any real file/dir row** — the tree has no `..` placeholder to
exclude, so the old `dirname == nav_dir` gate is dropped (the no-folder placeholder is still
excluded). The target dir threads through `nav_new`/`fs_apply_create`.

**Tests** (`smoke.tcl`, headless drives the procs directly): collapsed root lists only its
own rows; `nav_toggle_expand` unfolds a subdir (twisty flips, child renders indented, in
order) and re-folds; the fs.changed guard skips a change under a folded dir; New File targets
the row's own dir and auto-unfolds a subdir on create; the existing git-gutter pane tests
(dir rollup `·`, file `M`/`?`) still pass over the tree; `nav_col_is_arrow` is checked as a
column truth-table (arrow vs name at depth 0/1, files never an arrow). Out of scope:
persisting expand-state across launches; drag-to-reorder / drag between folders.

### D88 — Reopen the last folder on the next launch

Opening a folder, quitting, and relaunching `rio` came back to a **blank Files pane** —
the opened project was forgotten. The cause: the core holds "which folder is open"
(`rio::project::root`) in memory only, reset on every fresh process; nothing persisted it
and nothing reopened it. The per-project workspace restore (D31) is keyed by that root, so
it silently resolved to the *anonymous* session (D72) on a bare launch — the D31 resume only
ever worked when the folder was named on the command line (`rio <dir>`, which opens it before
the restore runs).

**Decision: the GUI remembers the last folder and reopens it at boot.** The last-opened root
rides `prefs.json` (the GUI's persistence home, D31/D56) under a new `project` key, mirrored
in `::last_project`. `on_project_opened` records it; a new **`reopen_last_project`** runs in
the boot sequence *before* `session_restore` (so the workspace restore has a root to key on)
and, when argv opened nothing, reopens it via the normal `project.open` path. That single
reopen is also what makes D31's per-project file resume actually fire on a bare launch.

**Local cores only.** A project root is a path on the *core's* filesystem; in remote mode
(`::core_remote`) that is a **server** path this GUI can't stat and mustn't reopen against a
different core — so `on_project_opened` records nothing in remote mode (a remote root never
clobbers the remembered local one) and `reopen_last_project` no-ops. **The core stays the
owner of "which folder is open":** if a persistent local daemon already holds a project,
`reopen_last_project` **adopts** it (via `project.get`) rather than overriding it with the
remembered path — the remembered path is only a fallback for when the core has none. A folder
that has since vanished is skipped silently.

**Still not persisted** *(at D88; lifted by D89)***:** the *unfolded-dir set* within the
project (`::nav_expanded`). This decision remembered **which folder**, not the tree's open
shape. Tested in `smoke.tcl` (that suite attaches over a socket, so the block forces the local
branch like the drop-routing test): open records `last_project`; it round-trips `prefs.json`;
`reopen_last_project` adopts an already-open core project, reopens a remembered one when the
core has none, skips a vanished folder, no-ops when a project is already open, and no-ops on a
remote core.

### D89 — Remember the tree's unfolded shape; survive a folder deleted underneath

Two follow-ups to D88, one feature and one robustness pair.

**Remember what's unfolded.** D88 (and D87) left the *unfolded-dir set* (`::nav_expanded`)
unpersisted — a reopened project showed its root collapsed. Now it resumes. The home is **not**
`prefs.json` (where D88 put the root) but the **per-project workspace session** (`rio::workspace`,
D31) — the same store that already remembers which files were open, keyed by the project root
and pruned to paths that still exist. That is the honest home: the tree shape is per-project
content, exactly like the open-file list, and putting it there buys a property the root pointer
can't have — it **follows the project onto a remote host** (D30), so it works in remote mode too
(the root reopen is local-only because the root is a server path). `workspace.save`/`get` and
the store gained an `expanded` list beside `open`/`active` (wire: a newline-joined string in,
a JSON array out, pruned on `get` against `file isdirectory`); `session_save` sends
`[dict keys $::nav_expanded]`, `session_restore` refills the set (after the project is open, so
it keys on the right session) and repaints, and `nav_toggle_expand` saves on every fold/unfold.
A session file written before D89 simply lacks the key and reads back an empty set.

**Edge — the project's own folder is deleted on disk mid-run.** Previously the next repaint ran
`fs.list` on the vanished root, which failed into a `report_error` **dialog** (and a recursive
`rm` could pop several). A gone root isn't an error to shout about — it **closes the project**.
`populate_nav` now probes the root's `fs.list` **once** (the core's stat, which also works in
remote mode where the GUI can't see a server path): on failure it resets `::nav_root`/`::nav_expanded`
to empty and falls through to the `(no folder)` placeholder, and forgets the reopen pointer if
this root was it (`::nav_root eq $::last_project`, so a remote root never wipes the remembered
*local* one). The probe's entry list is handed to the new **`nav_render_entries`** (split out of
`nav_render_level`) so the root isn't listed twice. A vanished *sub*dir needs nothing: its
parent's listing simply omits it, so the recursion is never entered for it — the `report_error`
path now only catches a genuine race or permission fault.

**Edge — the remembered folder is gone at the next launch.** `reopen_last_project` already
skipped a non-directory `::last_project`; now it also **clears** it (in memory; persisted on the
next `prefs_save`) so launches stop chasing a dead path and `prefs.json` self-tidies.

**Deliberately *not* done: deleting the orphaned core session file.** When a project is forgotten
we clear the *pointer* but leave its `rio::workspace` session on disk, because (a) the session is
keyed by the path's hash, so if the folder is ever recreated there the open-files + unfold shape
legitimately resume, and (b) forgetting an arbitrary root would force the *frontend to name a
non-current root* — the one thing `rio::workspace`'s "the frontend never names the root" rule
exists to prevent. The residue is one tiny JSON file per distinct project ever opened; a real
sweep would be a core-side GC, out of scope here.

**Tests.** Core `workspace.test`: `expanded` round-trips the pure store and through the ops,
prunes a vanished dir, and a pre-D89 file (no key) reads empty; the wire encoder emits the third
array. GUI `smoke.tcl`: the unfolded set persists into the session and `session_restore` refills
it and renders the child; a deleted root closes to the placeholder with **no** dialog and forgets
the pointer; the launch-time skip clears a dead pointer.

---

## 4. "Simple debug/terminal" — scope decision

rio ships **no terminal pane and no terminal emulator** (see D15). It does keep a
**headless command-execution primitive** in the core — run a command, capture
stdout/stderr and exit code — but that is plumbing for git (D7) and the agent
(D20), not a user-facing terminal. Manual testing and interactive debugging are
done in the user's **own external terminal**; that's the endorsed workflow.

**Why:** an interactive PTY emulator (esp. cross-platform, and worst of all
terminal-in-terminal under Ck) is a large, fragile subsystem out of all
proportion to a "simple IDE," and the user least needs it — real debugging
happens in a real terminal. Keeping only the headless run-command primitive that
git/agent already require gives us everything functional with none of the UI
weight. (A fuller terminal could be revisited far later — Ck even has a terminal
widget, see O1 — but it is explicitly *not* a v1 surface.)

---

## 5. UX sketch

Wide (GUI window or full-screen terminal) — three columns, status-only bottom
(no terminal pane — D15):

```
┌─────────┬────────────────────────────┬───────────────┐
│ ▾ FILES │ main.tcl ×  diff: app.tcl ×│ ▾ AGENT       │
│   app/  │             │              │  > refactor.. │
│   core/ │  <editor>   │  <editor 2>  │  • proposed   │
│ ▾ GIT   │             │  (side-by-   │    edit ▸diff │
│  M app  │             │   side diff) │   [apply][x]  │
│  + core │             │              │ ┌───────────┐ │
│         │             │              │ │ ask rio…  │ │
├─────────┴────────────────────────────┴─┴───────────┴─┤
│ main ●2↑  utf-8  Tcl   ln 12 col 4        rio-core ◇ │  ← status only
└──────────────────────────────────────────────────────┘
   nav            editor (1–2 groups)        chat
```

There is no bottom pane to toggle — command output the agent produces appears
inline in the `chat` column (D15).

Narrow (small terminal) — single column; side panes become stacked collapsible
sections; diff collapses to unified:

```
┌──────────────────────────┐
│ ▸ FILES                  │  collapsed (header only)
│ ▸ GIT                    │
├──────────────────────────┤
│ main.tcl ×               │  tabs
│ <editor, full width>     │
│   …                      │
├──────────────────────────┤
│ ▾ AGENT                  │  expanded (toggled)
│  > refactor parser       │
│  • proposed edit ▸diff   │  (unified diff inline)
│  [ ask rio… ]            │
├──────────────────────────┤
│ main ●2↑  ln12 c4        │  status (always)
└──────────────────────────┘
```

(No terminal section exists in either tier — command output appears inline in
the `AGENT` section; D15.)

Both renderings come from the **same** region model (D13) and layout policy
(D14); only the toolkit drawing differs (Tk geometry vs Ck geometry). The
`▾`/`▸` markers are the one collapsible-section primitive, reused throughout.

---

## 6. Open Questions

> **Triage (per Sequencing).** *Active now* (**core + GUI** phase): O2, O3, O7.
> O1 (the Ck spike) is **DONE** — Ck is a viable TUI toolkit (the keyboard is the
> real cost; see O1) — and the **TUI itself is now deferred** to a separable,
> later (possibly outsourced) effort; it is **not** active work. The protocol
> seam (D1/D2/D11) stays first-class so that TUI, or any third-party client, can
> attach later without touching core. *Resolved:* O5 → D21, and parts of O3 →
> D22, O6 → D23. *Deferred* (agent/plugin era — designed, not to be answered
> yet): O4, O8, O9, O10, O11, O12. Don't burn effort on the deferred ones before
> a working core+GUI exists.

- **O1 — The Ck spike — DONE; TUI deferred.** Validated `ck8.6` against rio's
  actual needs; see `spike/` (throwaway probe harness) and
  `spike/probes/VERDICT.md` (the full verdict). **Decision:** the spike did its
  job — it proved the *toolkit* can carry a TUI (rendering/editing/reflow/colour/
  Unicode all work) and surfaced the one real cost (**cross-terminal keyboard** —
  only `Ctrl-a` reached the app on a bare Debian terminal). With that confidence
  banked, **the TUI itself is deferred** to a separable, later, possibly
  outsourced effort, and is not tracked as active work. Core + GUI is the focus;
  the **D1/D2/D11 protocol seam stays the public contract** so a TUI (or any
  client) attaches later without touching core. The spike + VERDICT are the
  resume kit; the D2 safety net (a TUI in another language) is the fallback if
  Ck's keyboard story can't be made good. Result detail:
  - **Build & run:** vzvca/ck8.6 builds on Debian 13 / GCC 14, but only with
    legacy-C flags (`-fcommon`, demote the now-default implicit-decl/implicit-int
    *errors* back to warnings) passed via `make CFLAGS=` (its `configure` ignores
    env `CFLAGS`). Built `--enable-shared`, so run with `LD_LIBRARY_PATH` at the
    build dir. Captured in `rio-dev-deploy.sh --with-ck`. **Pinned:** Ck `@1a991e3`, Tcl 8.6.16,
    ncursesw 6.5.
  - **Editing surface (D-risk):** Ck's `text` handles a 5000-line buffer with a
    working `scrollbar`, typed editing, and `-foreground` tags — usable. ✓
  - **Responsive layout (D9, the core UX risk):** ✓ — but Ck has **no
    `<Configure>` event** (binding it errors). It handles SIGWINCH internally and
    fires **`<Expose>`**, with `winfo width` updated; the collapse rule binds
    `<Expose>` **and must guard on actual width change** (else
    `<Expose>`→repack→`<Expose>` loops and blanks the screen). The TUI frontend
    inherits this rule.
  - **Unicode:** BMP renders incl. box-drawing (pane borders) and wide CJK;
    astral/emoji are lost (ncursesw BMP limit) — rio needs none. ✓
  - **Keyboard / redraw:** in tmux, Ctrl/Alt/Fn/nav chords all deliver and a
    ~20 fps repaint loop is clean. **Still owed (human, can't be judged
    headless):** chords across xterm/tmux/**Cygwin** (D6), and the *feel* of
    redraw/latency. Until those settle O1 is PASS-on-Linux, not fully closed.
  - **On fail (Cygwin/feel):** the D2 safety net stands — reimplement the TUI in
    another language against the protocol; core is unaffected.

  **Timing — the spike gates the TUI, but is not the immediate next task.** Two
  things were being conflated: a *throwaway spike* (prove Ck can carry the
  existing protocol; deliverable is a leak-list, then discard) vs. a *parallel
  second frontend* (a real TUI kept in lockstep with the GUI). We reject the
  latter now — two dumb views over a still-moving protocol doubles the working
  set per change for no payoff yet. The spike (the former) is *cheapest now*
  (tiny op surface) but also *lowest-signal now*: the one terminal-hostile seam,
  theme fonts, is already consciously handled (the role table is data the GUI
  *applier* maps — D24 — so a TUI maps the same colour roles to a palette), and
  `line.col` (D12) already suits a cell grid. The spike earns its keep against
  the first **rendering-heavy** namespace — the agent chat panel or a git diff
  view — where the GUI-shape temptation is real and a terminal consumer would
  catch a leak before it's baked in. **So: run the spike as a throwaway right
  before designing the first rendering-heavy feature, not as the next task.**
  Until then the GUI is a sufficient single consumer; keep the core honest by
  *designing each new op with the terminal in mind* (thinking, not a parallel
  build — that captures most of the "two consumers keep the abstraction honest"
  benefit without the maintenance tax). **Update (superseded):** the spike was
  run at the toolkit level and PASSED, and the **TUI is now deferred** (see O1) —
  so the "run it right before the first rendering-heavy feature" timing is moot.
  What carries forward is the *discipline*, not a near-term TUI build: keep
  designing each op with a terminal client in mind so the protocol seam stays
  honest. The *protocol leak-list* part of the spike's intent now happens
  whenever the (deferred) TUI is actually built against the protocol.
- **O2 — Protocol details.** Core shape decided in D11 (JSONL,
  request/response/event); **value encoding now decided in D25** (shape-aware,
  string leaves, opaque-string ids). Implemented so far: `buffer.*` (text,
  replace, new, close, **list**), `fs.*` (open, save, **list**), `edit.*` (undo,
  redo), `session.hello` (version/capability negotiation), `theme.get` (D24 role
  table), `exec.run` (the command-execution primitive, below), `git.*`
  (status, diff, log — the read layer, below), `project.*` (open, get — the
  workspace root, below), `diff.lines` (the line diff backing the compare view —
  D28), and `agent.*` (send, approve, reset, history, **proposal** — the
  compare view's pull op, D28). The **error taxonomy is now
  decided** (below). Remaining: the full op vocabulary + params per namespace.

  **Error taxonomy — implemented.** An error reply's `error` is a flat object
  `{code, message}`, not a bare string: a stable machine-readable `code` clients
  branch on, plus a human `message` for display/logging. The vocabulary is
  deliberately small — `bad_request`, `unknown_op`, `no_buffer`, `no_path`,
  `bad_index`, `io_error`, `internal` (the catch-all for any uncaught Tcl error,
  so an overlooked failure still returns a clean reply, never a stack trace). An
  op raises `rio::error::raise <code> <message>`, which rides the code on Tcl's
  `-errorcode`; `dispatch` reads it back and shapes the reply (`rio-core/error.tcl`,
  `rio-core/dispatch.tcl`). Making `error` an object **bumped the protocol to 2**
  — the first breaking wire change since `session.hello` began reporting it. The
  GUI now checks `ok` before reading `result` and surfaces failures through one
  `report_error` seam, so a failed op shows a dialog instead of crashing (this
  closed a real bug: switching to a pruned tab dereferenced a missing `result`).

  **`session.hello` — implemented.** A client's first request; the core replies
  `{protocol, name, ops, fsroot}` — the wire protocol version (an integer that bumps on a
  breaking change; now **2**, see the error taxonomy), the implementation identity
  (`rio-core`), the ops it
  actually has registered, read live from the dispatch registry so the list can
  never go stale (`rio::dispatch::opnames`), and the root of the core's own
  filesystem (**D55**: `/` on POSIX, `C:/` on Windows — the frontend browses the
  core's disk and must not assume which). The reply is the second non-flat
  shape — `ops` is an array of *strings* — and reuses the result-encoder registry
  from `buffer.list` (a new `rio::wire::strarr` leaf). Client capabilities sent as
  params are accepted but not yet acted on; that negotiation can grow here.
  *(`fsroot` was added later and did **not** bump the protocol: an added key is
  additive, a client too old ignores it and a core too old omits it — see D55.)*
  *(Later: the GUI actually performs the handshake — `hello_core` greets every core
  it attaches to, at startup and after an in-place reconnect (D30), and warns
  plainly on a protocol mismatch instead of letting a version skew surface as ops
  quietly misparsing. A spawned child can't realistically mismatch; a daemon
  reached over `--connect` can be any age.)*

  **`buffer.list` + wire-array — implemented.** `buffer.list` returns
  `{buffers <array of {buffer,name,path,linecount}>}` from `rio::doc::inventory`
  (open buffers in creation order; view-local state stays in the frontend per
  D22). This was the first *non-flat* result, and it settled **how an op declares
  a non-flat shape** (the open question above): the op still returns a plain Tcl
  dict (so the in-process path is unchanged), `dispatch` passes the `op` name
  along on the reply, and `rio::wire` keys a small **result-encoder registry** by
  op — so the encoder is *told* the shape rather than guessing from Tcl values
  (D25). `rio::wire::arr` joins already-encoded fragments; unregistered ops fall
  back to the flat-object encoder. This is the pattern the next non-flat results
  will reuse.

  Implemented since: `theme.get` (D24, nested-object result) — the *core* theme
  service — plus the GUI **theme applier** that consumes it (named fonts, live
  per-widget re-config, a View menu that switches themes with no restart).

  **`exec.run` — the command-execution primitive — implemented.** The headless
  capability git (D7) and the agent (D20) build on (D15; rio has no terminal
  pane, so it never renders — output surfaces in the asking flow). `exec.run
  {argv, ?cwd?, ?stdin?}` -> `{exitcode, stdout, stderr}`, with stdout/stderr
  captured on separate streams (`rio-core/exec.tcl`, `rio-core/ops-exec.tcl`).
  Decisions: the command is an **argument vector, never a shell string** — no
  shell means no quoting/injection surface and identical behaviour on Windows
  (no `/bin/sh`); that argv discipline is the baseline guardrail. A command that
  **runs and exits non-zero is a successful op** whose `exitcode` is *data* (a
  failed test/git is not a protocol error); only a failure to *launch* (no such
  executable, missing cwd) raises — `io_error`. A signal-killed child reports
  `exitcode -1`. Output is captured as **faithful bytes** (no EOL/encoding
  translation, matching D22); an encoding policy can refine that later.

  **Scope — synchronous now, streaming later.** This first cut blocks until the
  child exits, which suits the pre-spike need: git `status`/`diff`/`log` are
  short. **Streaming** a long-running command's output as events over time (build
  output, the agent watching a test run) needs the event-loop/coroutine model
  (D10) and a way to deliver events outside a single request — deferred to the
  rendering-heavy era, alongside the O1 spike. Residual hardening (allow-lists,
  agent confirmation, and closing Tcl `exec`'s redirection-token surface — an
  argv element literally `>` is still reserved) is the **O4/D20** guardrail work,
  also deferred; trusted internal callers (git/agent) construct argv today.

  **`git.*` read layer — implemented.** The first consumer of `exec.run`: git by
  shelling out and parsing porcelain (D7, no libgit2). `git.status {?cwd?}` ->
  `{branch, changes:[{x,y,path,?orig?}]}` parses `status --porcelain=v1 -b -z`
  (NUL-terminated, so paths with spaces/newlines are safe; renames/copies carry
  `orig`); `git.diff {?cwd?, ?path?, ?staged?}` -> `{diff}` returns the raw
  unified diff for the worktree or the index (`--cached`); `git.log {?cwd?,
  ?max?, ?path?}` -> `{commits:[{hash,short,author,date,subject}]}` parses a
  field-delimited `--pretty` (US `0x1f` between fields, NUL between commits under
  `-z`) so any field — including a spaced subject — is unambiguous. A non-zero
  git exit (not a repo, bad path, no commits yet) becomes `bad_request` carrying
  git's stderr; git missing is `io_error` from `exec.run`'s launch path.
  `git.status` and `git.log` each register a D25 result-encoder (their array
  result). Read-only and UI-less — the pre-spike foundation git's UI and the
  agent build on (`rio-core/git.tcl`, `rio-core/ops-git.tcl`). Tests build a
  throwaway real repo and skip cleanly if `git` is absent (a `hasgit`
  constraint). **Remaining** (the rendering-heavy era, with the spike): write ops
  (stage/unstage/commit), and surfacing all this in a frontend.

  **`project.*` — the workspace root — implemented.** rio is "the editor with a
  project open": one canonical **root folder** the core holds (`rio-core/project.tcl`),
  the thing that anchors everything otherwise relative — the `cwd` for `git.*`,
  the directory `fs.list` walks for the file tree, and the per-project `.rio/`
  dir (D21). Before this, `git.*` leaned on the core process's own working
  directory; the root makes "the project" an explicit, queryable fact instead of
  an accident of how rio was launched. **Single-root by design** (a workspace is
  one open folder, matching one git repo); multi-root can grow later without
  changing this seam. `project.open {path}` -> `{root}` validates the path is a
  directory, records the normalized absolute root, and **emits `project.opened`**
  so every view (file tree, git pane) resyncs through one event (D3/D11);
  `project.get` -> `{root}` reads it back (`""` if none). `rio::project::resolve`
  is the shared rule frontends mean by a path: empty = the root, relative = joined
  onto it, absolute = as-is.

  **`fs.list` — directory listing for the file tree — implemented.** `fs.list
  {?path?}` -> `{path <abs dir>, entries:[{name,type}]}` lists one directory,
  resolving `path` against the project root (omitted = the root). **Lazy by
  design** — one directory per call, so a frontend expands a subtree on demand
  rather than the core walking a whole repo. Entries are dictionary-sorted
  (so `a2` precedes `a10`, case folded), `type` is `dir`|`file` (following
  symlinks, so a linked dir is expandable), and **dotfiles are included** —
  hiding them is a frontend choice, not the data layer's. The list proc is
  `rio::fs::listdir`, deliberately *not* `list`: a proc named `list` would shadow
  the Tcl builtin for every unqualified `[list …]` in the `rio::fs` namespace.
  `fs.list` registers a D25 result-encoder (its `entries` array).

  **GUI file pane — implemented.** The first non-editor pane: a left-hand
  navigator (`rio-gui.tcl`) that is a *dumb view* of the project root (D3). "Open
  Folder…" (Ctrl+Shift+O, or a directory argument on the command line) calls
  `project.open`; the pane repaints from the **`project.opened` event** — the same
  event-driven path as `buffer.changed`, not a direct return — so a second view
  would stay in sync for free. It lists one directory via `fs.list` (lazy:
  dirs-then-files, `..` to ascend, double-click/Enter to descend or open a file in
  a tab), and is themed through the existing role applier (reusing the `ui.*`
  role; a dedicated sidebar role can come later). A listbox navigator, not yet an
  expandable indented tree — the simplest honest first cut; tree-style expansion
  is a later enrichment.

  **`git.*` now anchors to the project root — implemented.** The git ops'
  `cwd` defaults to the open project root (`rio::project::root`) instead of `""`,
  so a frontend calls `git.status`/`.diff`/`.log` with no `cwd` and gets the open
  project's git — the (future) git pane no longer leans on the core process's own
  working directory. An explicit `cwd` still overrides (a tool on another
  checkout); with neither, `rio::git` falls back to the process cwd as before.
  This was the small follow-on that made the workspace root the real anchor for
  the git read layer.

  **GUI git pane + the side dock — implemented.** The file pane and a new **git
  pane** now share one **side dock** that shows *exactly one* at a time
  (`rio-gui.tcl`): a selector row (Files | Git) switches them, `show_pane` packs
  one body and hides the other. The git pane is a dumb view of the git read layer
  against the open project — `git.status` fills a branch header + changed-file
  list (`XY path`), selecting a file fetches `git.diff` into a read-only diff area
  (staged shown via `--cached` when a path is staged-only); a Refresh control
  re-reads, since there is no file-watching, and it is honest when there is no
  folder open or no repo. **The dock's side is a user choice, not dictated**
  (D13): a View-menu radio puts it Left or Right (default **Left**), `place_dock`
  re-packs it on either edge with the editor filling the rest. **The dock is also
  resizable by dragging** a thin sash between it and the editor (resize cursor on
  hover); `sash_drag` recomputes the dock's fixed width from the pointer measured
  against the *toplevel's* stable edge, clamped so neither the dock nor the editor
  collapses, and works on whichever edge the dock holds. The toplevel runs with
  geometry propagation off, so a drag flexes the editor instead of resizing the
  whole window (referencing the dock's own moving edge, or letting the window grow,
  fed the drag back on itself and made the panes jump). Both panes refresh
  off the `project.opened` event. Themed through the existing role applier (the
  diff area takes the editor surface; the selector is coloured like the tab bar).
  Layout choices are **runtime-only for now** — persisting them (dock side, active
  pane, wrap) across launches is the D21 config plumbing, still to come. **Remaining:**
  git write ops (stage/unstage/commit) once the read view earns them, a roomier
  diff view, and `git.log` history in the pane.

  **Editor scrollbars + line wrapping — implemented.** The editor is now a text
  widget gridded with a vertical and a horizontal scrollbar in a container frame
  (`.ed`; the text is `.ed.t` so the bars can be its siblings — everything still
  drives it through that path/proxy and `::rio_real_t`). A **View ▸ Wrap Lines**
  checkbutton (Ctrl+Shift+W) toggles `-wrap none`/`word`. The horizontal bar
  auto-hides (`gridscroll`, the grid sibling of the dock's pack `autoscroll`) when
  no line runs past the edge, and `apply_wrap` drops it entirely while wrapping,
  where horizontal scrolling is meaningless. Default is no wrap. Wrap state is
  persisted with the other prefs (D31, `prefs.json`).

  *(2026-07-23 — wrapped-line indent.)* By default Tk shows a logical line's
  leading indentation on its **first** display line only; the wrapped continuation
  rows fall back to the left margin. **View ▸ Indent Wrapped Lines** (`::wrap_indent`,
  persisted) turns on VSCode's "wrappingIndent: same" — each continuation row is
  indented to sit under its own line's first non-whitespace char. It is a pure
  display layer, deliberately **decoupled from the highlighter** so it works on
  plain files too: a per-line `-lmargin2` tag (`wrapind:<cols>`, one shared tag per
  distinct indent depth) sized to the line's leading whitespace — columns computed
  by expanding tabs to the widget's 8-stops, times the monospace column width
  (`font measure RioEditorFont 0`; `restyle_group` re-sizes the tags on a font/theme
  change). Tk tags ride with the text on insert/delete, so `apply_change` recomputes
  only the lines an edit actually touched, never the whole buffer — and `load_buffer`
  sizes a buffer on open/switch. No visible effect while wrap is off; the tags wait.
  Tests: the wrap-indent group in `rio-gui/tests/smoke.tcl` (column math, per-line
  tagging, incremental re-tag on edit, clear-on-toggle) and the prefs round-trip in
  `session.tcl`.

  **GUI agent chat pane — implemented (D26 slice 2).** The right-hand `chat`
  column (D14): a dumb view (D3) over the `agent.*` event stream — a read-only
  transcript, a few-line composer (Enter sends, Shift+Enter newlines), and Send
  (`rio-gui.tcl`). It calls `rio::core::call_stream` with a *live* `emit`
  (`chat_event`) — the streaming counterpart of the batched `rio_call` seam — so a
  turn's `agent.delta` chunks append under one
  **Agent** block as they arrive (the answer builds in view), `agent.message`
  closes the turn, and `agent.error` renders a classified failure block. The pane
  is always on the right with its own draggable `.csash` (mirror of the dock sash),
  toggled by **View ▸ Agent Chat** (Ctrl+Shift+A); the core owns the conversation
  (D3), so *Clear* is `agent.reset` and the transcript could be rebuilt from
  `agent.history`. Themed via the `chat.bg`/`chat.fg` roles + `RioChatFont`, accent
  on the speaker labels (D24). Visibility + width are runtime-only (D21 later).
  *(Rewired by D30 P3: `chat_send` now sends `agent.send` as a plain op over the
  one channel and the turn's `agent.*` events arrive as ordinary broadcast traffic —
  `dispatch_event` routes them to `chat_event`; there is no `call_stream`/`agent_event`
  in-process sink anymore.)*

  **GUI provider selection + Claude key entry — implemented (D26 slice 3).** A
  **Settings** menu picks the live agent provider — *Echo (offline)* or *Claude
  (API key)* — via `apply_provider`, which calls `rio::agent::set_provider` and
  names the active provider in the chat header (`Agent · Echo` / `Agent · Claude`).
  *Settings ▸ Claude API Key…* opens a small modal (`claude_key_dialog`) that is a
  dumb view of the `claude-api` face's key store: it hands a typed key to `set_key`
  or removes it with `clear_key` (a 0600 secret; the dialog never retains the key),
  with a *Show key* reveal and a *Clear* enabled only when one is stored. Selecting
  Claude with no key isn't blocked — the first turn surfaces the face's actionable
  `not_configured` error, pointing back to Settings. The choice of provider is
  runtime-only; the key is the durable state. The headless smoke exercises all of
  it against a throwaway secret dir (`rio::secret::override_dir`).
  *(Rewired by D30 P3: `apply_provider` now calls the `agent.provider.set` op and the
  key dialog the `agent.key.set`/`clear` ops + `agent.status` — provider, key, and the
  auto-accept policy are core-side, selected by name from `rio::agent`'s provider
  registry, so the same GUI drives a local or a remote core identically.)*
- **O3 — Document model details.** Representation decided in D12 (lines-list,
  `line.col`); encoding, line endings, and cursor locality decided in D22 and now
  *implemented* (`rio-core/fs.tcl`, `fs.*` ops). Undo/redo is now *implemented*
  too: per-buffer undo/redo stacks in the document model with a recording `edit`
  primitive distinct from the raw `replace`, surfaced as the `edit.undo`/
  `edit.redo` ops (`rio-core/ops-undo.tcl`); each undo emits the same
  `buffer.changed` event a normal edit would, so views resync through one path.
  *(Later hardened: the undo record keeps the **clamped** start/end, not the
  caller's raw request. `_splice` pins an out-of-range column to its line's end
  and now reports that effective range back through `replace`; `edit` records it,
  so a non-GUI client sending a column past the line — the GUI always sends
  widget-normalized indices — no longer leaves undo unable to reverse the span the
  text actually occupied.)*
  **Remaining:** keystroke coalescing into undo groups, and large-file handling
  (lazy load?).
- **O4 — Agent tool surface & safety.** (Scoped by D20 to the *core*
  orchestration. Its **read slice is built — D26 slice 4** (the four read-only
  built-ins, auto-executed through a core tool-loop, project-root-confined and
  size-capped) and its **propose-edit / write slice is built — D26 slice 5**: the
  `propose_edit` / `propose_create` tools, the `agent.propose`→`agent.approve`
  approval gate with a diff review, apply-via-`buffer.replace`+`file.save` /
  `fs.write` (root-confined), and the `apply_writes_disk` / `auto_accept` policy
  flags — provider-agnostic, so no plugin change was needed. The **run-command
  slice is now built too — D83**: the `run_command` tool through the same gate
  (always gated — auto-accept is edits-only), run **asynchronously** via
  `rio::exec::start` and **timeout-bounded**, argv-only with a redirection-token
  guard and cwd confined to the project — which **closes** exec's redirection-token
  surface on the agent path. **D84** then adds an **opt-in, human-authored allow-list**
  (standing approval — a command the user marked trusted skips the bar; the rails still
  run), refining D53 to "no *silent* autonomy, a human authors every rule" rather than
  "no allow-list at all".) Still open here: surfacing the write-policy flags as
  persisted config (D21), the permission model for plugin-contributed tools, and a
  truncation/scrollback rule for long command output surfaced in `chat` (the
  per-read size cap applies today; streaming output over time is deferred with D10).
- **O5 — Config & session format.** ✅ **Resolved — D21** (plain key-value
  settings + JSON session state, XDG locations, per-project `.rio/`).
- **O6 — Default keymap.** ✅ **Resolved — D23 + D38.** Binding *model* in D23
  (data-driven, GUI/TUI parity); the concrete default scheme and the modal
  stance in D38: the **windows** editing mode is the default feel, and modal
  editing ships as the first-class **vi** mode (emacs beside it), all three
  swappable in Settings ▸ Editing Mode.
- **O7 — Distribution & build.** Starpack/`vanillawish` packaging per platform;
  how `tcltls` (for Claude HTTPS) is bundled.
- **O8 — Extension API versioning.** Stability/versioning policy for the
  contribution API once plugins exist; capability negotiation (ties to
  `session.hello`, O2).
- **O9 — Plugin performance tiering.** Threshold where chatty contributions
  (e.g. per-keystroke highlight on large files) need the in-process tier or
  batching (D16).
- **O10 — SDK & declarative-UI specifics.** Which SDK languages ship first
  (Tcl given; reference SDK — Python? Lua?) and the concrete schema/vocabulary
  for declarative UI contributions (D18).
- **O11 — Store / distribution architecture.** ✅ **Resolved — D39** (revising
  the git leaning): distribution is plain-HTTP directory repositories
  (apt-sources model, no central index), with an in-app install UI (the
  Extensions window) that proved worth building. Still open within it, tracked
  in ROADMAP: trust/signing without a central authority (the
  `.well-known/rio-repository` hook is specced), plugin-kind installs, and
  update checking.
- **O12 — MCP alignment.** Whether/how to map the provider and agent-tool
  interfaces onto MCP; rio as MCP client (consume MCP servers) and possibly MCP
  server (expose rio to other agents) (D20).

---

### O1 spike — detailed spec

A **throwaway** probe (not rio code) to prove/disprove that Ck can carry the
TUI before we commit. Time-boxed. Produces a written verdict that closes O1.
**When to run it:** not next — just before designing the first rendering-heavy
namespace (agent chat / git diff), where a terminal consumer has the most to
catch. See O1's Timing note above.

**What it must prove (each is pass/fail):**

1. **Build & run.** `ck8.6` (or `vanillatclsh`) builds/runs on Linux and under
   Cygwin. Pin the exact build/version used.
2. **Editing surface.** Ck's `text` widget works as a code editor: multiline
   insert/delete, scroll/viewport over a ~5k-line file, an insert cursor/mark,
   line navigation, and **tags for at least foreground color** (syntax / diff).
   Catalogue what it *can't* do vs Tk's `text`.
3. **Responsive layout (D9).** Build the real rio shell in Ck — editor pane +
   collapsible side panes (tree/git/chat) via `grid`/`pack` — and confirm it
   **reflows horizontal → vertically stacked on terminal resize** (SIGWINCH),
   cleanly. This is the core UX risk.
4. **Keyboard (D5).** Bindings incl. Ctrl/Alt modifiers and function keys work
   and are consistent across xterm, tmux, and the Cygwin console / Windows
   Terminal.
5. **Unicode.** UTF-8 text renders (BMP at minimum; note wide/combining-char
   behavior).
6. **Redraw correctness & latency.** No flicker/garbage on resize, scroll, or
   fast typing; input latency acceptable.

**Pass bar:** editor pane usable for real editing; layout reflows correctly; no
show-stopping redraw bug; keyboard coverage sufficient for our keymap.

**On fail:** invoke the D2 safety net — reimplement the TUI in another language
against the protocol (Perl/`Curses::UI` first candidate). Core is unaffected.

## 7. Documentation plan

Professional, maintained across these documents (audiences — users,
contributors, agents):

- **AGENTS.md** (this file) — design & decision log for agents/contributors.
- **README.md** — user-facing intro, status, quickstart.
- **INSTALL.md** — the **canonical home for install & deployment**: requirements,
  the two deploy scripts, local vs. remote (server mode over SSH), where the
  agent's key lives, troubleshooting. README/CONTRIBUTING only *point* here —
  keep deploy specifics out of them so they can't drift.
- **PITCH.md** — a short landing-page pitch (food for a static-site generator):
  what rio is and why, for someone who's never heard of it.
- **CONTRIBUTING.md** — for **human programmers** who hack on rio: build, test,
  conventions. Points here for the "why"; build/test sections firm up with O7.
- **rio wiki** (separate `rio-wiki.git`) — comprehensive user documentation,
  eventually with screenshots. *Hold screenshots until there's a UI to show.*

**Keep them in sync.** A change that shifts a decision lands in AGENTS.md *with
its why*; a deployment change lands in INSTALL.md; user-facing changes in README.
Don't let the same fact live in two docs where it can drift.

---

## 8. Glossary

- **core / `rio-core`** — the UI-less Tcl library holding all logic.
- **frontend** — a thin view layer (GUI or TUI) over core.
- **server mode** — core running headless; frontends connect over a socket.
- **Ck** — Tk-shaped toolkit rendering to curses; the TUI's toolkit.
- **command-execution primitive** — the headless core capability to run a
  command and capture its output/exit code; feeds git and the agent. *Not* a
  terminal pane (rio has none — D15).
- **region** — a fixed logical area of the layout: `nav`, `editor`, `chat`,
  `status` (D13).
- **editor group** — one tabbed editor column; the center holds one or two
  (two = side-by-side / diff).
- **collapsible section stack** — the single reusable UI primitive (`▾`/`▸`
  sections) backing both the left nav and narrow-mode pane collapse (D13/D14).
- **layout tier** — wide / mid / narrow, chosen by the D9 policy function from
  available width (D14).
- **plugin** — a protocol participant that extends rio; out-of-process (any
  language) or in-process Tcl (D16).
- **contribution point** — a thing a plugin can register: command, keybinding,
  event subscription, provider, or UI contribution (D17).
- **SDK** — a thin per-language wrapper over the protocol for writing plugins;
  lives outside the core (D16).
- **manifest** — a plugin's declaration of identity, contributions, and
  permissions (D19).
- **first-party plugin** — a rio-shipped plugin built on the public extension
  API, used to dogfood it (D17).
- **provider** — a plugin implementing the core LLM provider interface (Claude,
  local LLM, …); supplies the model, absorbs the wire specifics (D8, D20).
- **MCP** — Model Context Protocol; a JSON-RPC standard for exposing
  tools/resources to LLM apps. Candidate basis for rio's provider/tool
  interfaces (D20, O12).
- **extension repository** — a plain http-served directory carrying
  `rio-repository.conf`, an optional `index`, and one subdirectory per
  extension; named in the user's `sources.list`. No central index (D39).
- **provenance ledger** — the GUI-side record of installed extensions
  (`extensions.json`): which source URL and version each `kind/name` came
  from, and its payload files (D39).
- **Extensions window** — the non-modal *Settings ▸ Extensions…* browser: one row
  per (kind, name), every variant with its provenance in the detail section;
  rio's first D35-style tool window (D39).
- **safe-name rule** — `^[A-Za-z0-9][A-Za-z0-9._-]*$`, required of every
  remote-supplied name before any URL/path join (D39).
