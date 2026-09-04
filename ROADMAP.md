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

- **Live file-watching in the core** — *deferred* (AGENTS.md D47). The file pane now
  refreshes on rio's own core writes (`fs.changed`), on regaining OS focus, and on a
  manual ⟳ — which covers external changes at the "alt-tab back" moment without a poll.
  The *proper* answer for truly live updates (a file appearing while rio is focused, from
  a build or another tool) is OS notifications in the core — inotify / kqueue / FSEvents —
  emitting `fs.changed`, reusing the D47 event and working remote for free. Deferred for
  its cost: Tcl has no built-in inotify, so it means a C extension or shelling to
  per-platform watchers — a dependency plus a platform matrix — against the no-heavy-deps
  grain. The focus-return refresh is the cheap 90% stand-in until then.
- **File-management refinements** — *deferred* (builds on AGENTS.md D48, which shipped
  New File / New Folder / Rename / Delete as core `fs.*` write ops off the row menu).
  Consciously left: **inline in-pane rename** (v1 uses a modal name prompt — the D45
  commit bar is the reusable inline primitive when this is wanted); move via
  drag-and-drop; multi-select delete; duplicate/copy; and nested-path creation from one
  prompt (v1 validates a single path component). None are structural — each is an added
  verb or an alternative input on the same `fs.*` ops.
- **Line-number gutter extras** — *deferred* (builds on AGENTS.md D49, which shipped the
  VSCode-style gutter, on by default, per editor group; **click a number to select its
  line** then landed as D61). Consciously left: **relative line numbers** and gutter
  numbers in the side-by-side **compare panes**. Each rides the same `gutter_redraw` seam —
  an alternate number source or a second call site — not a structural change.
- **Menu overflow at scale** — *deferred.* The fixed menus (File/Edit/View/Settings) are
  kept within screen height by grouping into submenus (AGENTS.md D64). Still open: the
  **data-driven, unbounded** menus — the **Theme** cascade (grows with installed themes,
  D39) and the **Tabs** list (one entry per open buffer) — can exceed screen height no
  matter how they're grouped, and Tk's native tall-menu scroll is unreliable on X11 (see
  [CAVEATS.md](CAVEATS.md)). The fix when wanted: render those two with the scrollable
  `rl_*` rich-list component (same pattern as the Files/Git/Extensions panes and the
  Preferences theme dropdown) — a bounded height + scrollbar, never a screen-tall posted
  menu. Not taking the Tk-native-scroll path (X11 menu internals are fragile — the D59
  lesson).
- **Window / taskbar icon** — *deferred.* rio sets no `_NET_WM_ICON`, so the xfwm4 title
  bar and the xfce4-panel taskbar each fall back to their own default (hence the mismatch).
  jka has a custom pixmap icon in mind; the fix is `wm iconphoto . -default` with the image
  at a few sizes (16/32/48). Note this is a *raster* asset, distinct from the mono-Unicode
  in-UI iconography rule — a glyph would have to be rendered to a pixmap first.
- **Files pane — richer view, later** — *deferred* (builds on AGENTS.md D42/D43: the
  pane is a rich-list drawn with a read-only text widget, now a shared `rl_*`
  component the git pane also uses, and file rows carry git-status flags). Candidates:
  an expandable Explorer-style tree (structural change to the flat navigator);
  drawn-bitmap icons if glyphs prove too plain. (Hiding dotfiles from the navigator, with
  a show-hidden toggle, landed as D62.) The larger fork — **core-backed
  read-only "view buffers"** (emacs-like modes for dired/git/log, re-backing the
  rich-list widget with the core) — is noted but *not taken*; today the pane is
  deliberately GUI-local chrome, not a buffer.
- **Undo-coalescing in the doc model** — *deferred.* Typing currently records
  fine-grained undo steps; batching a run of keystrokes into one undo unit is a
  noted refinement in the core document model. (Also felt in vi mode: one
  operator is one undo, but insert-state typing stays per-keystroke.)
- **Editing-mode extensions** — *deferred* (AGENTS.md D38, D41). The core ships the
  Windows mode; emacs and vi now ship as installable extensions (`extensions/`,
  D41) so they can grow on their own cadence. Consciously left for later: vi ex
  commands (`:w` `:q`), named registers, `.` repeat, macros, marks, visual-line —
  and a kill ring (`C-y` yank) for the emacs mode. Each is an isolated addition to
  its `modes/*.tcl` module (now the extension's payload).
- **Column-editing extras** — *deferred* (AGENTS.md D40). Column/block editing
  shipped (Ctrl+Shift+drag a vertical cursor; type/Backspace/Delete/Tab down the
  column, one undo). Consciously left: rectangular clipboard (Ctrl+C/X/V carrying
  the block), keyboard-built columns (Alt/Ctrl+Shift+arrows), tab/pixel-accurate
  visual columns (v1 uses character columns), and arbitrary multi-caret
  (Ctrl+click) — a straight generalisation of the same one-span-replace model.
- **Search extensions** — *in progress* (AGENTS.md D36, D51, D52). In-buffer Find/Replace
  shipped (bar + core-side `buffer.find`/`buffer.matches`/`buffer.replace_all`); **Find in
  Files** landed (D51: core-side `project.search`, a bottom results panel with per-hit
  highlighting); and the panel **grew into a unified Search panel** (D52, Phase A): three
  scopes — **Project** (disk, `project.search`), **Open docs** and **Current doc** (live
  buffer text, new `buffers.search`) — behind one scope selector, on one shared line-grouped
  matcher (`rio::doc::grep_lines`), with the find bar able to **escalate** into it. A **replace
  row** then landed across all three scopes (D52 Phase B): buffer scopes via `buffer.replace_all`
  (undoable, unsaved), Project via a new confirm-gated `project.replace` that edits open files
  through their buffers and rewrites closed files on disk (one shared `rio::doc::_replace_text`).
  **Regex** then landed as a flag on every search/replace op + a toggle on both surfaces (D52
  Phase C): line-oriented Tcl-ARE patterns with `\1`/`&` backreferences in replace, centralized
  in `rio::doc::_regex_spans`. **Whole-word** rides every literal path (one shared
  `rio::doc::_bounded` rule). The panel is now a normal **D35 bottom dock-site tenant** carrying
  its query row in its own in-body header (`.results.hdr`), like Files/Git/Agent. Still wanted:
  one **row per match** rather than per line, and richer scope filters (globs, honour `.gitignore`).
- **Dock-site system for tool windows** — *complete (a+b+c1+c2+c3; the search-fold was tried and rejected)* (AGENTS.md D35 +
  its Refinement). Tool panels (the agent chat today; a git log, search results, a REPL,
  extension panels later) become first-class views hosted by a small set of dock sites
  (left/right/bottom), each a tabbed container the user can move panels between — the Visual
  Studio docking model, kept distinct from the document editor groups (D33). Gives
  user-controlled placement and one universal embedding seam for D17/D18 UI contributions,
  without overloading the core `buffer` concept. The **Refinement** now fixes the build
  shape: v1 hosts *core-team panels only* (files/git/chat/results — the plugin
  UI-contribution seam is deferred); a data-registry **panel contract**; one persisted
  `layout` object replacing the `dock_side`/`dock_pane`/`chat_shown` flags; the find bar and
  compare view stay OUT (they aren't tool windows); and an incremental path whose opening
  move is **extracting a reusable panel component** and migrating the four existing panes
  onto it (no behaviour change). **Step (a) is done:** the `rio::panel::*` registry now
  declares files/git/chat/search as data and routes their refresh through one dispatch (no
  behaviour change; 19 smoke checks). **Step (b) is done:** the persisted `layout` object (three
  sites × `{panels, active, visible, size}`) is now the single source of truth, and one
  `apply_layout` derives all non-document placement from it (replacing `place_dock`/`show_pane`/
  the bottom-strip packing); the old `dock_side`/`dock_pane`/`chat_shown` flags became read
  mirrors and were dropped from prefs (clean cut). Dock/chat sizes now persist. 27 smoke checks
  (migration, normalize, JSON round-trip, live derivation). **Step (c1) is done:** three site
  containers each with a host-owned tab strip; `apply_layout` renders every visible site (tab
  strip + active body packed via `-in`); uniform chrome (chat/search get tabs too, VS docking
  style); the Files/Git selector and `style_selector` retired; sashes generalised. 332 smoke
  checks — but the *visual* result isn't headless-verifiable and wants a live look. **Step
  (c2) is done:** every tab takes a right-click "Move to ▸ Left/Right/Bottom" (`panel_move`) —
  any panel to any site, so the sites are now rearrangeable (the Agent can join the left dock,
  git can go to the bottom). **Step (c3) is done:** drag a tab and drop it on another site (a
  press/motion/release state machine, 6px threshold, accent-lit drop target) — the D35 "done"
  gesture. **D35 is complete.** A *search-fold* was tried (query row into the tab strip) and
  **rejected** on a live look: it mixed the query controls with the tabs, made them compete for
  width, and singled Search out (Files/Git keep their ⟳ in the body; the Agent composer can't
  fold into a one-line strip at all). Settled rule: **tab strip = tabs only; controls live in the
  panel body**, placed **by control weight** — *browse* panes (Files/Git) put their thin caption
  (name + glyph button) at the **top**; *compose* panes (Chat/Search) put their heavy control
  area (input field + full controls) at the **bottom**, content above, so the input is in the
  same place when switching between them.
  *Parked design idea:* a future **per-panel `controls: top | bottom`** override (right-click a
  panel → Top/Bottom, persisted in the `layout` object beside active/visible/size) to flip an
  individual pane against its weight-class default.
  The chat stays a dedicated pane (D14) by choice. Quality bar for these panes: the D36 find
  bar — dynamic (appears only when needed), clean, minimal controls. The
  **Extensions window (D39) is the first tenant-in-waiting**: it ships as a
  non-modal tool window and re-hosts into a dock site when this lands. The **git
  pane is the natural first *extension* tenant** once this and a stable plugin
  UI-contribution seam exist — an extension can't contribute a GUI panel today (real
  kinds are only syntax/mode/theme), so extracting git is premature and its cost is
  these two missing seams, not the git code. When it comes, D43's files-pane git flags
  make the boundary a shared **git-status service** (git publishes status; the
  navigator subscribes if the extension is present, degrading to no-flags exactly like
  the current no-repo case) rather than a clean lift-out of "the git pane".

## Syntax highlighting

- **More languages** — *ongoing.* Each highlighter is one self-contained
  `syntax/<lang>.tcl` file (per-line `scan` contract, AGENTS.md D32), so adding a
  language is isolated work — good first contributions. Shipped: (X)HTML, XML, CSS,
  JavaScript, TypeScript, Perl, Tcl, shell, Batch/cmd, PowerShell, awk, sed, Makefile,
  Dockerfile, Markdown, PHP, Python, Lua, C, C#, C++, Go, Rust, JSON, YAML, TOML, INI,
  SQL, Ruby, Java, Kotlin, Swift, Scala (XML reuses the (X)HTML scanner; Makefile and
  Dockerfile match by whole file name, D46). That covers the common set and Notepad++'s
  built-ins — further ones are whatever a contributor reaches for next (R, Haskell,
  CMake, Diff, …), an isolated drop-in each. Diff would want added/removed roles the
  fixed token vocabulary doesn't have yet — a small vocabulary question, not a drop-in.
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

- **Write operations** — *in progress* (AGENTS.md D44, D45). Stage / unstage / track
  landed as `git.add` / `git.unstage` (D44); **commit** landed as `git.commit` (D45),
  driven from an auto-showing single-line commit bar in the git pane — rio's first
  inline pane text-input. Still wanted: **discard changes** (`git restore` / removing an
  untracked file — destructive, so behind a confirm), and a **multi-line commit
  message** body (v1 is a single summary line).

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
