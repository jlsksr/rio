# rio — possible next steps

A running list of candidate work: things rio could grow into next. It is a
*shortlist of possibilities, not a set of promises* — items here are ideas and
deferrals we want to keep in view, in no strict priority order. Some are planned
features, some are known gaps, some are refinements deliberately deferred with a
reason. Anything that turns into a real decision (why, and how) gets written up in
[AGENTS.md](AGENTS.md); the short user-facing teaser stays in the README's *Still to
come*. Items get struck out and removed here as they land.

Each entry notes its state:

- **planned** — intended, just not built yet
- **gap** — a rough edge we know about
- **deferred** — consciously postponed; the *why* is recorded
- **design** — needs a decision before code

## Editor & UI

- **File-pane auto-refresh** — *gap.* The file tree doesn't update when the agent
  creates a file; it refreshes on the next manual reload. Fold into a proper
  file-pane pass.
- **Undo-coalescing in the doc model** — *deferred.* Typing currently records
  fine-grained undo steps; batching a run of keystrokes into one undo unit is a
  noted refinement in the core document model. (Also felt in vi mode: one
  operator is one undo, but insert-state typing stays per-keystroke.)
- **Editing-mode extensions** — *deferred* (AGENTS.md D38). The windows/emacs/vi
  modes shipped; consciously left for later: vi ex commands (`:w` `:q`), named
  registers, `.` repeat, macros, marks, visual-line — and a kill ring (`C-y`
  yank) for the emacs mode. Each is an isolated addition to its `modes/*.tcl`
  module.
- **Column-editing extras** — *deferred* (AGENTS.md D40). Column/block editing
  shipped (Ctrl+Shift+drag a vertical cursor; type/Backspace/Delete/Tab down the
  column, one undo). Consciously left: rectangular clipboard (Ctrl+C/X/V carrying
  the block), keyboard-built columns (Alt/Ctrl+Shift+arrows), tab/pixel-accurate
  visual columns (v1 uses character columns), and arbitrary multi-caret
  (Ctrl+click) — a straight generalisation of the same one-span-replace model.
- **Search extensions** — *deferred* (AGENTS.md D36). In-buffer Find/Replace
  shipped (bar + core-side `buffer.find`/`buffer.matches`/`buffer.replace_all`);
  still wanted: whole-word and regex options (a flag on the same ops), and
  **Find in Files** — core-side like the in-buffer engine (in remote mode only
  the core sees the project tree), surfacing as a search-results panel in a
  dock site once D35's tool-window mechanism exists.
- **Dock-site system for tool windows** — *design* (AGENTS.md D35). Tool panels
  (the agent chat today; a git log, search results, a REPL, extension panels later)
  become first-class views hosted by a small set of dock sites (left/right/bottom),
  each a tabbed container the user can move panels between — the Visual Studio docking
  model, kept distinct from the document editor groups (D33). Gives user-controlled
  placement and one universal embedding seam for D17/D18 UI contributions, without
  overloading the core `buffer` concept. Direction settled; not built — the chat stays
  a dedicated pane (D14) until it lands. Quality bar for these panes: the D36 find
  bar — dynamic (appears only when needed), clean, minimal controls. The
  **Extensions window (D39) is the first tenant-in-waiting**: it ships as a
  non-modal tool window and re-hosts into a dock site when this lands.

## Syntax highlighting

- **More languages** — *ongoing.* Each highlighter is one self-contained
  `syntax/<lang>.tcl` file (per-line `scan` contract, AGENTS.md D32), so adding a
  language is isolated work — good first contributions. Shipped: (X)HTML, CSS,
  JavaScript, Perl, Tcl, shell, Markdown, PHP, Python, Lua, C, C#, C++, Go, Rust, JSON.
  Still wanted: Java, Kotlin, Ruby, YAML, TOML, SQL, etc.
- **Viewport scoping** — *deferred* (AGENTS.md D32 amendment). Re-highlighting is
  now incremental, so per-edit cost is already small; viewport would only cap the
  one-time whole-file scan on very large files and needs scroll-event machinery not
  yet warranted.
- **Highlight the compare/diff panes** — *deferred.* v1 highlights the main editor
  only; the side-by-side compare view is still plain.

## Extensions & distribution

Repositories shipped (AGENTS.md D39): plain-HTTP sources, the Extensions
window, provenance-marked installs for syntax/modes/themes. Consciously left
for later:

- **Repository TLS / other transports** — *deferred.* v1 is plain `http://`
  only; rio implements no TLS of its own (operators front a webdir with
  relayd/nginx). Candidates when warranted: https via tcltls (already a core
  dependency for the agent), ssh-fetched repositories, and git-backed sources
  (dropped from v1 — see the D19 annotation).
- **`.well-known/rio-repository` badges** — *planned.* The host-validation
  file is specced (CONTRIBUTING) and costs publishers one line; consuming it —
  a "host-validated" badge in the Extensions window, and an official-approval
  marking on top — is not built.
- **Signing / trust beyond provenance** — *design.* v1's trust model is apt's
  (your sources list is your trust list, provenance shown, code named as
  code). Anything stronger — signatures, pinning — needs a design that works
  without a central authority.
- **Plugin-kind installs** — *deferred* (D19). The `kind` vocabulary is open
  and the manifest grows unknown keys compatibly, so protocol-participant
  plugins (with declared permissions) can become installable kinds once the
  plugin interface stabilises.
- **Update checking** — *deferred.* rio never auto-updates; an update is
  installing the newer-listed variant by hand. A "newer version available"
  marker on installed rows would be a cheap, honest middle ground.
- **Core-side ledger** — *gap.* The provenance ledger is GUI-side ("this GUI
  installed X onto its core"); a second frontend on the same daemon doesn't
  see it. Theme installs land core-side already; the ledger could follow.

## Git

- **Write operations** — *planned.* Git is read-only today (status + diffs). Stage,
  unstage, and commit are the obvious next step.

## Agent

- **Run-command tool (with guardrails)** — *planned.* Let the agent run shell
  commands under explicit approval/confinement, alongside its existing read and
  propose-edit tools.
- **Agent instructions in the GUI** — *planned* (AGENTS.md D34). The agent's system
  prompt now ships as an editable data file (`agent/prompt.md`) with a per-project
  `.rio/agent.md` layer; still wanted is a Settings view to read/edit the active
  instructions (like the keybindings editor, D23) and a `.rio/agent.md` scaffold.
- **Per-provider prompt coda** — *deferred* (AGENTS.md D34). The provider contract
  can carry a short model-specific tail appended to the shared base; unneeded so
  far, the seam is in place for when a provider wants one.

## Remote / transport

- **`--ssh` wrapper** — *planned.* A convenience front for the manual
  SSH-tunnel-then-`--connect` recipe (channel-transport plan, P4): spawn the tunnel
  and attach in one step. The underlying remote-core path already works.

## Frontends

- **Ck terminal frontend (TUI)** — *deferred.* A spike proved Ck can carry it
  (rendering, editing, reflow, colour, Unicode), so the risk is retired, but building
  the terminal frontend is a separable later effort. It attaches over the same
  language-neutral protocol, so it lands *without touching the core*.

## Project & packaging

- **Plugin interface** — *design.* Plugins (LLM providers, extra agent tools) exist,
  but the public interface is still being shaped and will change; not yet a stable
  contribution surface. (Syntax highlighters, by contrast, are stable today.)
- **Install / packaging path** — *planned.* A polished install and packaging story
  beyond the dev/server deploy scripts (see [INSTALL.md](INSTALL.md)).
- **License & code of conduct** — *planned.* To be added before rio opens up to
  outside contributions.
