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

- **Monochrome-Unicode iconography** — *deferred.* Icons are to be plain monochrome
  Unicode glyphs (not `.ico` files or colour emoji), themed like the rest of the UI.
  Design settled; implementation not started.
- **File-pane auto-refresh** — *gap.* The file tree doesn't update when the agent
  creates a file; it refreshes on the next manual reload. Fold into a proper
  file-pane pass.
- **Undo-coalescing in the doc model** — *deferred.* Typing currently records
  fine-grained undo steps; batching a run of keystrokes into one undo unit is a
  noted refinement in the core document model.

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
