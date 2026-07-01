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
**agent** (read + propose-edit, Claude over the official Anthropic API). The GUI
is **always a client to the core over a channel** — a pipe to a private core it
spawns locally, or a socket to a remote core; **there is no in-process path**
(D29/D30 retired it). Still mapped-but-unbuilt: the TUI, the full plugin
platform, git write ops, and the agent's run-command surface — see Sequencing.
Decisions carry an *Implemented* note where code now backs them.

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
> (API key), read + propose-edit — while the heavy run-command guardrails stay
> deferred (O4). The agent's first providers ride the
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
stays open — that's the narrowed O6.

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

### D26 — Agent subsystem, first slice: `agent.*` protocol + provider interface; in-box Claude over the official Anthropic API

Activates the **core-orchestration slice** of the agent (D20 / O4) now that a
working core + GUI exists. Scope is deliberately narrow; the heavy run-command
guardrails stay deferred (O4).

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
  a one-line edit, not a rebuild.
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
against `api.anthropic.com`, and the exposed-as-config UI for the write policy /
the run-command tool with its allow-list guardrails (O4).

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
**View ▸ Compare With File…** (active buffer vs. a picked
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
refinement (as undo-coalescing is in the doc model). Only the main editor is highlighted
for now (not the compare panes). A file with no registered highlighter, or a scratch
buffer with no path, simply shows plain text.

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
  `{protocol, name, ops}` — the wire protocol version (an integer that bumps on a
  breaking change; now **2**, see the error taxonomy), the implementation identity
  (`rio-core`), and the ops it
  actually has registered, read live from the dispatch registry so the list can
  never go stale (`rio::dispatch::opnames`). The reply is the second non-flat
  shape — `ops` is an array of *strings* — and reuses the result-encoder registry
  from `buffer.list` (a new `rio::wire::strarr` leaf). Client capabilities sent as
  params are accepted but not yet acted on; that negotiation can grow here.

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
  runtime-only (D21 later).

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
  **Remaining:** keystroke coalescing into undo groups, and large-file handling
  (lazy load?).
- **O4 — Agent tool surface & safety.** (Scoped by D20 to the *core*
  orchestration. Its **read slice is built — D26 slice 4** (the four read-only
  built-ins, auto-executed through a core tool-loop, project-root-confined and
  size-capped) and its **propose-edit / write slice is built — D26 slice 5**: the
  `propose_edit` / `propose_create` tools, the `agent.propose`→`agent.approve`
  approval gate with a diff review, apply-via-`buffer.replace`+`file.save` /
  `fs.write` (root-confined), and the `apply_writes_disk` / `auto_accept` policy
  flags — provider-agnostic, so no plugin change was needed. The **run-command**
  guardrails below remain **deferred** per Sequencing.) Still open here: surfacing
  the write-policy flags as persisted config (D21), guardrails for the headless
  run-command primitive (now
  implemented as `exec.run` — see O2; its argv-not-shell discipline is the
  baseline, but allow-lists, agent confirmation, and closing exec's
  redirection-token surface remain here), the permission model for
  plugin-contributed tools, and a truncation/scrollback rule for long command
  output surfaced in `chat`.
- **O5 — Config & session format.** ✅ **Resolved — D21** (plain key-value
  settings + JSON session state, XDG locations, per-project `.rio/`).
- **O6 — Default keymap.** Binding *model* decided in D23 (data-driven, GUI/TUI
  parity). **Remaining:** the concrete default key scheme and whether any modal
  editing is offered — pinned down once there's an editor to feel.
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
- **O11 — Store / distribution architecture.** Leaning git-based (plugin = git
  repo; default catalog a self-hosted Forgejo, configurable, host-agnostic — see
  D19). Open: clone/pull install + update flow, version/compat pinning, how
  trust/signing works without a central authority, and whether any in-app
  install UI is worth it vs. a documented `git`-and-config convention (D19).
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
