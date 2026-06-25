# AGENTS.md — rio

> Working notes for agents, contributors, and maintainers. This is a **living
> decision log**: it records not just *what* we decided but *why*, so future
> work doesn't re-litigate settled questions or lose the reasoning behind them.
> Keep it current. When a decision changes, edit the decision and note the
> change — don't silently overwrite history.

Status: **brainstorming / pre-implementation.** No code written yet. Nothing
below is built; this captures the agreed design direction.

> **Sequencing (read this).** This is a **multi-phase** project and there is **no
> application yet.** The full design space (agent, plugins, server) is mapped
> below, but we build in order: first a working **core + GUI** that edits real
> files, with the **Ck spike (O1)** to validate the TUI path.
>
> Mind the difference between **designing a seam** and **building a platform.**
> The plugin/protocol **boundary** (D2, D11, D16) is designed in from **day one**
> so nothing has to be bolted on later — but *building out* the full plugin
> **platform** (contribution API, manifests, permissions, SDKs — D17–D19) and the
> **agent subsystem (O4)** is **deferred**: do **not** dive deep into their
> implementation before a working core + GUI exists. The agent's first providers
> ride the *thin* protocol-participant transport (essentially D11), **not** the
> full platform. The **marketplace** (O11) is deferred further still. Depth in
> this design log ≠ priority to build.

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
- **Optional** server mode (GUI/TUI connect to a headless core, like
  `emacs-server` / `vscode-server`). Optional — in-process is the default.
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

- **`rio-core`**: pure Tcl, zero UI dependency. ~80% of the code and *all*
  business logic. Document model, undo, file I/O, git (shell out to `git`,
  parse porcelain), LLM/agent orchestration, project/session state, command
  dispatch.
- **Frontends** (`rio-gui`, `rio-tui`): thin. They render core state and turn
  input into core commands. No business logic.

**Why:** one separation solves three requirements at once — (a) GUI+TUI without
duplicated logic, (b) optional server mode, (c) "simple, readable" by keeping UI
toolkits out of the logic.

### D2 — The core API is a *message protocol*, transport-independent (protocol-first)

The core exposes a request/response + event-stream API designed as a protocol
from day one, **independent of transport**:

- **In-process** (default, no server): transport is a direct in-memory call.
- **Server mode**: the *same* commands marshaled over a Unix socket / TCP.

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
- **Response** (core → client): `{id, ok: true, result}` or `{id, ok: false, error}`
- **Event** (core → client, unsolicited): `{event, params}` — broadcast to all
  attached views.

Encoding is **JSON, one message per line** (JSONL framing) over the socket; the
in-process path uses the same dict structure with no serialization cost.
Streaming ops (`cmd.run`, `agent.send`) emit a sequence of events keyed by a
`runId` / `sessionId`, terminated by a final event. Op namespaces:
`buffer.*`, `fs.*` / `project.*`, `git.*`, `cmd.*`, `agent.*`, `session.*`.

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
  hand-editing.

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
productivity" aesthetic); themes are opt-in. `solarized-light` and
`solarized-dark` ship as example files under `$XDG_CONFIG_HOME/rio/themes/`. A
theme may optionally declare `base = <theme>` and override a few roles rather
than copy the whole set.

**Scope:** theming is a **GUI concern** (D1) — fonts have no meaning in a
terminal. But the **color-role vocabulary is shared**, so a future TUI theme can
map the same roles onto the terminal's 16/256-color palette without inventing a
second model.

**Why:** roles-not-paths make a new theme a pure value set; named fonts give
per-section typography and instant, restart-free changes; refusing to execute
theme files reuses D21's security/robustness stance; a built-in default keeps the
look people love without a theme file present. **Open:** the concrete role
vocabulary (the full list of color/font slots) and how much rio leans on `ttk`
vs classic widgets — both firm up once the GUI shell exists.

### D25 — JSON value encoding is shape-aware, not value-sniffed

The canonical internal form is plain Tcl dicts (D11: the in-process path uses
them with no serialization), so JSON lives **only at the socket boundary**. A
*generic* dict→JSON encoder is impossible there — Tcl can't tell the string
`"hi there"` from the two-element list `{hi there}` — so the boundary encoder is
**shape-aware**, never guessing types from values:

- The **envelope shape is fixed**: `id` is a wire **string** (ids are opaque
  tokens on the wire), `ok` is a bare `true`/`false`, and a reply carries either
  `result` (object) or `error` (string).
- `result` and event `params` are **flat objects whose leaf values encode as
  JSON strings** — exact for every value the protocol carries today (text,
  `line.col` indices, ids, removed text). Inbound parsing uses tcllib's
  `json::json2dict`, which is unambiguous.
- When an op eventually needs a non-string leaf (a number, nested object, or
  array), **that op declares its shape**; we never sniff Tcl values for type.

**Why:** value-sniffing is the classic Tcl→JSON footgun (a string that happens
to look like a list or a number gets mis-typed); pinning the envelope and
treating leaves as strings is total, debuggable, and correct for the current
protocol, while leaving a clean path (per-op shape declarations) for richer
payloads. Keeping JSON at the boundary preserves D11's zero-cost in-process path.
Implemented in `rio-core/wire.tcl`; the socket transport (`server.tcl`) is the
same dispatch as in-process (D2), proven by a real-socket round-trip test.

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

> **Triage (per Sequencing).** *Active now* (core+GUI+TUI phase): O1 (spike),
> O2, O3, O7. *Resolved:* O5 → D21, and parts of O3 → D22, O6 → D23. *Deferred*
> (agent/plugin era — designed, not to be answered yet): O4, O8, O9, O10, O11,
> O12. Don't burn effort on the deferred ones before a working core+GUI exists.

- **O1 — The Ck spike (top priority, gates the TUI plan).** Validate
  `ck8.6` / `vanillatclsh` against rio's actual needs:
  - Responsive pane layout (D9) via Ck's geometry managers.
  - A usable editing surface in Ck's `text` widget (it's a weaker cousin of
    Tk's — no canvas, no embedded windows-in-text).
  - Acceptable behavior under **Cygwin** (D6) and on Linux.
  - Pin a specific build/version; treat Ck as a vetted dependency.
- **O2 — Protocol details.** Core shape decided in D11 (JSONL,
  request/response/event); **value encoding now decided in D25** (shape-aware,
  string leaves, opaque-string ids). Remaining: the full op vocabulary + params
  per namespace, the error taxonomy, and version/capability negotiation in
  `session.hello`.
- **O3 — Document model details.** Representation decided in D12 (lines-list,
  `line.col`); encoding, line endings, and cursor locality now decided in D22.
  **Remaining:** undo/redo structure and large-file handling (lazy load?).
- **O4 — Agent tool surface & safety.** (Scoped by D20 to the *core*
  orchestration; **deferred** per Sequencing.) Exact built-in tool set, how edits
  are previewed/applied, guardrails for the headless run-command primitive (D15),
  the permission model for plugin-contributed tools, and a truncation/scrollback
  rule for long command output surfaced in `chat`.
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

Professional, maintained across four documents (three audiences — agents,
contributors, users):

- **AGENTS.md** (this file) — design & decision log for agents/contributors.
- **CONTRIBUTING.md** — for **human programmers** who hack on rio: how to build,
  test, and contribute; code conventions. _Drafted_ (pre-impl); points here for
  the "why", build/test sections provisional pending O7.
- **README.md** — user-facing intro, install, quickstart.
- **rio wiki** (separate `rio-wiki.git`) — comprehensive user documentation,
  eventually with screenshots. *Hold screenshots until there's a UI to show.*

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
