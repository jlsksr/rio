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
- **A buffer notices the file changed under it** — *landed* (AGENTS.md D94). `file.open` /
  `file.save` stamp mtime+size into buffer meta; `buffers.stale` / `buffers.reload` /
  `buffers.stamp` answer core-side (in remote mode the file is on the server, D29) and take
  **lists**, so a bulk change is one round trip. A clean buffer reloads silently, a modified
  one asks, and a file deleted on disk asks Notepad++'s question — keep it in the editor, and
  a later Save recreates it. `git.discard` / `git.discard_all` emit `fs.changed` now too.
  Still missing: **live** watching — the triggers remain `fs.changed` and focus return, so
  this rides on the watcher above when it lands.
- **File-management refinements** — *deferred* (builds on AGENTS.md D48, which shipped
  New File / New Folder / Rename / Delete as core `fs.*` write ops off the row menu).
  Consciously left: **inline in-pane rename** (v1 uses a modal name prompt — the D45
  commit bar is the reusable inline primitive when this is wanted); move via
  drag-and-drop; multi-select delete; duplicate/copy; and nested-path creation from one
  prompt (v1 validates a single path component). None are structural — each is an added
  verb or an alternative input on the same `fs.*` ops.
- **Line-number gutter extras** — *deferred* (builds on AGENTS.md D49, which shipped the
  VSCode-style gutter, on by default, per editor group; **click a number to select its
  line** landed as D61, and **relative line numbers** — vim's hybrid — as D71).
  Consciously left: gutter numbers in the side-by-side **compare panes** — the same
  `gutter_redraw` seam at a second call site, not a structural change.
- **A theme picker that shows the themes** — *deferred* (builds on AGENTS.md **D92**, which
  retired the unbounded Theme cascade into the bounded `pick_dialog`). Today the picker lists
  theme *names*; the richer variant previews them — either a **swatch per row** (each row drawn
  in the colours of the theme it names) or **live preview** (moving the selection re-themes the
  editor, Cancel restores). What defers it is the **data cost, not the widget**: the GUI knows
  only names until it asks, so painting swatches means one `theme.get` per theme — N round-trips
  every time the dialog opens, over a channel that may be a socket to another machine (D29) —
  for a control you touch rarely. Live preview avoids that (it fetches only the row you land on)
  and is the cheaper half if this is ever wanted. A *multi-colour* row additionally needs the
  `rl_*` rich-list rather than the listbox — a Tk listbox colours a whole item, one
  foreground/background pair, but cannot vary colour *within* a row — which would put a second
  dialog idiom in the tree. Any of this would want a way to fetch several themes in one call
  before it's worth doing.
- **Window / taskbar icon** — *landed* (AGENTS.md **D117**). `wm iconphoto . -default` with
  seven sizes (16–256) plus a Windows `.ico`; soft, so a checkout without `icons/` still
  starts. The artwork is Christ the Redeemer, a pun on the name. Confirmed as a *raster*
  asset distinct from the mono-Unicode in-UI rule (D27). The early 16px light-chrome
  washout is **fixed** — an artwork is cut and judged at 16/24/32 over dark *and* light
  chrome before it ships. The three Flaticon variants that first passed that test were
  **removed** and replaced by the project's own artwork (**D120**): a licence that
  requires attribution says too little about redistributing the file itself, and the icon
  travels with every copy of rio. Artwork lives in `icons/sources/` with `icons/active`
  naming the current one, so switching is `make-icons.sh <name>`.
- **Files pane — richer view, later** — *partly landed* (builds on AGENTS.md D42/D43: the
  pane is a rich-list drawn with a read-only text widget, now a shared `rl_*`
  component the git pane also uses, and file rows carry git-status flags). The
  **expandable Explorer-style tree** — the big structural candidate here — landed as
  **D87** (the flat navigator became an unfoldable tree from the project root). Remaining
  candidate: drawn-bitmap icons if glyphs prove too plain. (Hiding dotfiles from the
  navigator, with a show-hidden toggle, landed as D62.) The larger fork — **core-backed
  read-only "view buffers"** (emacs-like modes for dired/git/log, re-backing the
  rich-list widget with the core) — is noted but *not taken*; today the pane is
  deliberately GUI-local chrome, not a buffer.
- **Undo-coalescing in the doc model** — *landed* (AGENTS.md **D90**). A run of
  single-character edits now merges into one undo step in `rio::doc::edit`, sealed at
  each blank, so undo takes back a word at a time (Enter always stands alone); vi's
  insert-state typing is covered too, while each normal-state command stays separately
  undoable via the additive `coalesce` flag on `buffer.replace`. Remaining candidate:
  an **idle-timeout** break (a pause in typing seals the run) — deliberately left out to
  keep the model free of a clock; adjacency and blanks cover the common cases, and it can
  be added later without a protocol change.
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
- **In-app help viewer (Help ▸ Contents…)** — *landed* (**D99**, **D100**). The
  window shows the manual: contents parsed from `index.md` on the left (an `rl_*` rich list), the
  selected topic **rendered** on the right, opened from ***Help ▸ Contents…*** or `F1` (a keymap
  command, so it is remappable). The GUI reads `docs/` off its own tree, never through the core,
  so a remote session shows *this* rio's manual. **D100** added the renderer — headings, lists,
  blockquotes, fenced code, fixed-pitch tables, bold/italic/inline code, and links a reader can
  click, including `#anchor` jumps within a page and the sibling documents `index.md` points at
  (`../README.md`) — with Back/Forward behind them. Prose re-wraps to the window's own width;
  code and tables do not. A **Find** box searches the manual — the contents list becomes the
  sections that mention the word, and picking one lands on that heading with the word banded.
  The panel-vs-window question is still open and deliberately unanswered:
  it is a non-modal tool window, the Extensions-window shape, which re-hosts into a dock site if
  that is where it lands.
  This entry previously also carried *"`docs/` installing"* — a leftover from D91, written
  against a packaging path that does not exist. rio is deployed by cloning it, so `docs/` is
  already beside the code wherever it runs; there was nothing to install. Dropped, not done.
- **`fs.read`'s doors have no guard yet** — *gap* (the other half of AGENTS.md **D125**,
  which guarded `file.open` — the door a person actually walks through). Three callers
  still read a whole file unbounded: the **agent's `read` tool**
  (`rio-core/agent-tools.tcl`, both the `fs.read` primitive and `_current_text`), and the
  **compare/diff view** (`rio-gui/rio-gui.tcl`, `fs.read` at the side-by-side load). The
  agent case is the sharper one — its 100 KB cap is applied to the *result*, after the
  whole file has already been read and decoded, so pointing it at a build log stalls the
  core for the full read and then returns 100 KB anyway. What makes this its own decision
  rather than a second line of D125: **declining is the wrong answer for at least one
  caller.** The agent should get a *prefix* — the first 100 KB off disk, truncated exactly
  as today but without paying for the rest — which needs a bounded-read primitive beside
  `rio::fs::read`, while the compare view probably wants D125's question. One rule, two
  answers, so it wants thinking through rather than pattern-matching.
- **Opening a very large file is still slow once you say yes** — *landed* (AGENTS.md
  **D126**). Three whole-file passes were removed and the budget followed the measurement
  up, from 8 MB to 64 MB: `rio::fs::_valid_utf8` now decides by a C-level encode/decode
  round trip instead of walking a Tcl byte list (164 → ~7 ms/MB), highlighting paints the
  visible window instead of the file (~1350 ms/MB → flat), and `buffer.text` is pulled in
  chunks so tcllib's `json2dict`, which is quadratic in the length of one JSON string,
  stays linear (8 MB: 1935 → 262 ms). An 8 MB open went from ~13 s to ~1.6 s, with
  highlighting on rather than stripped to Plain Text. Capping encoding detection at a
  prefix stays **rejected** — declaring a whole file UTF-8 on the strength of its first
  megabyte makes the read lossy — and lazy / windowed loading stays out of scope: the Tk
  text widget holds the document (it absorbs 20k lines in 4 ms), and find, marks,
  selection, `line.col` undo indices and the gutter all rest on that.
- **The two whole-file passes left in the open path** — *closed* (**D126**, measured).
  `wire::str` escaped every value with one 34-pair `string map`, twenty-nine pairs of which
  are C0 controls a document never contains; it now asks one regexp and runs either that
  same map or a five-pair one over a value proven not to need the rest (**56 → 20 ms/MB**,
  and no regression for a value that does contain a control). `fs::read` counted line
  endings with two `regexp -all` sweeps before normalising; the `string map` that follows
  loses exactly one character per CRLF pair, so the count is free from the length delta and
  the common case needs no sweep at all (**15.5 → 0.9 ms/MB** for an LF file). The EOL one
  is the computation whose wrong answer corrupts a file silently, so it is held to a
  differential test against the two-pass original rather than to examples.
- **Checkpointing the highlighter's scan** — *not planned*, and the reasoning that put it
  here was wrong. It said snapshotting the scan state every N lines "would make a *repeat*
  jump cheap": a repeat jump is already free, because `hl_enter` is a dense prefix that
  **persists**, so `hl_ensure` skips the scan entirely on a second visit. Checkpointing
  would trade that away for memory and buy nothing. The **first** jump is the only cost —
  most of a minute at 64 MB, chunked and non-blocking but real — and D126's follow-up
  measured where it goes: at **20.2 µs a line the scanner is 19.5 of them**, the per-line
  widget fetch was 1.7 (now bulk, 0.1) and the entry-state allocation was inside the noise.
  So the only lever left is a per-line "this line cannot change the entry state" fast path
  *inside the scanners*, which is an addition to D32's contract across 33 of them and needs
  a differential test per language. Its own decision, if anyone is ever annoyed enough.
  The memory half of this bullet is **closed**: entry states are now shared objects rather
  than one freshly allocated list per line (a 4 MB Tcl file has exactly **two** distinct
  ones across 131,072 lines), which cut `hl_enter` on an 8 MB read-through from **36.5 MB
  to 8.7 MB**.
- **A right-click menu in the editor** — *landed* (AGENTS.md D108). Right-clicking the text
  did nothing, while the file pane, the git pane and every tab handle had a menu. It carries
  the *Edit* menu's actions plus the find cluster, and needed **no new verbs**: one shared
  `editor_menu_items` table feeds both the menubar and the popup (so they cannot drift), and
  the entries are the procs that already existed. The click itself is the load-bearing half —
  inside a selection it survives, outside it the caret moves where you pointed — and it
  focuses the group it was in, so a right-click in the other half of a split acts on that
  half. `Menu` and `Shift+F10` open it at the caret.
  The two items D108 deferred both **landed as D115**: a *Copy / Select All* menu on the
  read-only views (agent log, compare panes, git diff, the manual, a plan), and
  *Cut / Copy / Paste / Select All* on the entry and text widgets Tk leaves bare outside
  the editor (find bar, chat composer, search rows, commit bar, dialog fields). The
  commands are Tk's own `<<Cut>>`/`<<Copy>>`/`<<Paste>>`/`<<SelectAll>>`, so the menu and
  the keystroke cannot drift. A masked field (the provider key) withholds Cut and Copy.
  Remaining candidate: a row menu for the **`rl_*` lists that have none** — Search results
  and the manual's contents, where Button-3 is bound to an empty callback. Left out of
  D115 deliberately: it means deciding what *Copy* or *Open* mean for a result row, which
  is a Search/Help feature rather than the missing door, and `rl_init` kills text
  selection in those panes anyway.

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
- **Viewport scoping** — *landed* (AGENTS.md D126, amending D32). The one-time
  whole-file paint turned out to be 81% of the cost of opening a large file, which is
  what warranted it. `hl_enter` became an exact *prefix* rather than an exact whole,
  `hl_lo`/`hl_hi` record what actually carries tags, and the scroll machinery it needed
  was one line in `edscroll`, since Tk's `-yscrollcommand` is already where the wheel,
  the scrollbar, `see`, vi's jumps and find's step all arrive.
- **Language from the shebang** — *deferred* (AGENTS.md D112). Detection is by file
  name only; an extension-less script (`bin/foo` starting `#!/usr/bin/env perl`) stays
  plain unless picked by hand (View ▸ Language…). A first-line fallback, used only when
  the name matches nothing, would need modules to register interpreter names
  (`perl`, `sh`, `tclsh`, `python3`, …) beside their extensions, and a re-check when
  line 1 is edited or the text is first loaded.
- **Highlight the compare/diff panes** — *deferred.* v1 highlights the main editor
  only; the side-by-side compare view is still plain.

## Extensions & distribution

Repositories shipped (AGENTS.md D39): plain-HTTP sources, the Extensions
window, provenance-marked installs for syntax/modes/themes. Consciously left
for later:

- **https repositories** — *landed* (AGENTS.md D109). `https://` sources beside
  `http://`, which stays first-class; verified against the core host's own CA
  store (system bundle, the Windows store, or `SSL_CERT_FILE`), needing tcltls
  1.8+ for host-name checks (the agent too, unless the user allows otherwise —
  D110). A certificate that doesn't verify can be reviewed and accepted, exactly
  that one, browser-style (D111). **Still open:** a first run on Windows; a way to
  accept a certificate from the agent's side, which today only honours one accepted
  in the Extensions window.
- **Other repository transports** — *deferred.* ssh-fetched repositories, and
  git-backed sources (dropped from v1 — see the D19 annotation).
- **`.well-known/rio-repository` badges** — *planned.* The host-validation
  file is specced (CONTRIBUTING) and costs publishers one line; consuming it —
  a "host-validated" badge in the Extensions window, and an official-approval
  marking on top — is not built.
- **Signing** — *landed* (AGENTS.md D118 and D119; designed with jka 2026-09-16, built
  2026-09-19 once rio.skylm.org/extensions was publishing signatures). It extends
  D39's apt-style trust model (the sources list is the trust list) without a central
  authority, the way D109/D111 did for transport. A publisher signs one root
  `SHA256SUMS` with an ed25519 SSH key as git does; rio verifies it by running
  `ssh-keygen -Y verify` on the core's host and checks every file it fetches against
  those hashes. A key is trusted when the **user confirms it** (D119) — the source is
  refused until then and the fingerprint is one click away, the way `ssh` asks — after
  which it is recorded in `repository-keys.conf` and a rotation is refused until the
  new key is confirmed too. rio's own repository is pre-trusted. Unsigned repositories
  stay allowed and are marked; once a source is trusted there is no downgrade.
  - **Known limits, unchanged:** confirming narrows the first-scan attack rather than
    closing it — an attacker on the path the first time can still offer a key that
    verifies, they just have to get a human to accept a fingerprint the publisher's own
    page contradicts; no freshness check (a replayed older `SHA256SUMS` only freezes
    updates, and D107 never downgrades); rotation is the "changed" step, with no
    cross-signing; no revocation (D109 addendum).
  - **The keys list landed too** (2026-09-19, deferred at first and built once the
    mechanism had settled): *Preferences ▸ Extensions ▸ Repository signing keys…* —
    every source, its fingerprint, when it was confirmed, and **Forget selected**, with
    rio's own pre-trusted key shown as a `(built in)` row so a fresh install doesn't
    look like it trusts nothing. Forget means what it says: the repository is refused
    again until a key is confirmed for it. Forgetting the built-in row withdraws even
    that. Nothing open here now.
- **Provider as an installable `kind`** — *landed* (AGENTS.md D66; D65's "milestone
  B", successor to D19). `provider` is a `kind` in the **same** repositories — one
  infrastructure, a publisher adds `kind = provider` (plus `provider-api` and
  `entry`) to a manifest. It installs **core-side** (`provider.put`, mirroring
  `theme.put`), behind the versioned `provider-api = 1` surface and a bespoke
  consent that names the credential/network trust; it activates on the core's next
  start (restart-to-activate — no sourcing remote Tcl into a running, possibly
  shared, core). The contract was hardened in-tree first (D65) so a second
  implementation proved the seam before it was frozen. OpenAI/ChatGPT was extracted
  from the tree to become the first such extension ([extensions/openai/](extensions/openai/)),
  and **Claude followed (D69)** — the core now carries **no** provider payload, only the
  `echo` stub, with every real provider installed. Still open here: `provider-api 2` and a
  core-side ledger (below).
- **Update checking** — *landed* (AGENTS.md D107). It went further than the
  "newer version available marker" deferred here, because the marker needed the
  thing D39 had refused: an **ordering over versions**. `version` is now
  **semver** — a published rule for authors, leniently parsed, and anything that
  isn't semver is shown but never compared. The Extensions window marks a row
  `[1.1.0 → 1.2.0]`, its button says *Update*, *Update All* takes the batch under
  one consent, and an opt-in check at start-up reports what it found. rio still
  **never auto-updates**, and an update comes only from the repository the
  extension was installed from (a per-extension flag opens that up) — with no
  central index, a shared name is not a shared identity.
- **Core-side ledger** — *gap.* The provenance ledger is GUI-side ("this GUI
  installed X onto its core"); a second frontend on the same daemon doesn't
  see it. Theme installs land core-side already; the ledger could follow.

## Git

- **Write operations** — *in progress* (AGENTS.md D44, D45, D80, D81, D93, D97, D98). Stage / unstage /
  track landed as `git.add` / `git.unstage` (D44); **commit** landed as `git.commit` (D45),
  driven from an auto-showing commit bar in the git pane — rio's first inline pane
  text-input — now with an optional **multi-line description body** behind a `＋` toggle
  (D81, joined to the summary as git's subject/body); **discard changes** landed as
  `git.discard` (D80) — a confirm-gated *Discard Changes…* (revert a tracked file to its last
  commit) / *Delete…* (remove a never-committed new file) — on the git-pane row menu **and,
  since D93, on the file-tree row menu** (tracked rows there; a new file is what the tree's own
  *Delete…* already removes). **Discard all** landed with it as `git.discard_all`, a single core
  op — `reset --hard` + `clean -fd -- :/`, ignored files untouched — behind a `↩` button that
  rides the git pane header only while the repo has changes. **Rename-aware discard** landed as
  **D97**: a rename is one change with two names, so discarding one now restores the original name
  and removes the new one (a copy `C` keeps the addition treatment — its source was never touched),
  and the op emits `fs.changed` for both names. **D98** closed the last blind spot in the doors:
  git collapses a wholly untracked folder into one `sub/` row, so a file inside one could not be
  staged from either pane — the file tree now offers **Track (git add)** on it, and the git pane's
  folder row admits to being a folder. Nothing outstanding in this entry.

## Agent

- **Providers** — *landed* (AGENTS.md D26, D65, D66, D69). The core now ships **only** the
  offline **`echo`** stub built in (D69); every real provider is an **installable**
  `provider` extension. **Claude** (Anthropic API, [extensions/claude/](extensions/claude/))
  and the **OpenAI-compatible** provider (**ChatGPT** by default; point its base URL at a
  local server — Ollama / llama-server / LM Studio / vLLM — to run a **local model**;
  [extensions/openai/](extensions/openai/)) both install from a repository like any other
  extension. Each keeps its own 0600 key; the GUI's provider picker + key dialog enumerate
  from the core (`agent.providers`). A first-party provider is a plugin mirroring these two;
  **anyone** can now publish one to a repository (see Extensions ▸ "Provider as an
  installable `kind`").
- **Run-command tool** — *landed* (AGENTS.md D83). The agent runs commands
  (`run_command`) through the same propose/approve gate as an edit, but **always
  gated** (auto-accept is edits-only), **argv-only** (no shell) with a redirection-
  token guard, **cwd-confined** to the project, run **asynchronously** so the core
  stays responsive, and **timeout-bounded** (default 120 s, max 600 s). Verified
  live against ChatGPT.
- **Trusted-command allow-list** — *landed* (AGENTS.md D84). An **opt-in**,
  human-authored list of commands that run **without** the approval bar — standing
  approval, not autonomy (a person authors every rule; refines D53). A rule is an
  **argv prefix**: a one-word rule (`pytest`) trusts every run of that program, more
  words (`git status`) trust only that start. **Three scopes mirror the prompt
  layers** — **global** (every project), **per-provider** (only while that provider
  runs), and **project** (`.rio/`) — and a command is trusted if **any active scope**
  allows it. Added one-click from the bar's **Always allow** menu (program or exact ×
  scope submenu) or managed per-scope in **Preferences ▸ Agent ▸ Allowed commands…**; it
  skips **only** the bar — `prepare_exec`'s guards still run. Verified live against
  ChatGPT (global + per-provider auto-run, zero approvals).
  Still wanted: **streaming** a command's output as it runs and a per-command
  **Stop/cancel** (both need the D10 event-over-time model); command output in its
  **own dock panel** rather than inline in the chat; a richer rules editor.
- **Plan mode** — *landed* (AGENTS.md D101). ***Settings ▸ Agent Mode ▸ Plan*** withholds
  every changing tool from the provider — reads plus one new gated built-in,
  **`present_plan`** — and adds a shipped **plan prompt layer**. The plan arrives as an
  `agent.propose` of kind `plan` carrying Markdown and takes the **center**, rendered with
  the manual's renderer (D100) beside the chat's Approve/Reject bar; approving it flips the
  mode back to `build` **inside the same turn** (the loop recomposes tools and prompt every
  step) and the agent carries the plan out, each edit still gated. Every presented plan —
  rejected ones included — is filed under the project's `.rio/plans/`. Provider-agnostic by
  construction: the tool list and the system prompt are composed in the core, so nothing in
  `extensions/` knows plan mode exists.
  Still wanted: a browser over `.rio/plans/`; a **keyboard chord** for the mode (the keymap
  is D23 data, so one can be added without touching this).
- **The mode as one control, and the plan as the place you choose** — *landed*
  (AGENTS.md D102). The agent's three states — **Plan / Review / Auto** — are one menubutton
  in the chat header (twinned as a Settings cascade and Preferences radios), derived from the
  core's two flags so the UI can no longer show "plan mode" over an armed auto-accept. A
  plan's bar carries **`Approve ▾`** with the two ways to say yes (*review each edit* /
  *auto-accept edits*): the edit policy is chosen once the plan has been read, not set
  beforehand. **`Edit plan`** opens the filed `.rio/plans/` file as an ordinary buffer, and
  the core re-reads it at approval through the live buffer — so an unsaved edit is what the
  agent is handed. Closes D101's "editing a plan" item.
- **A plan on request, in any mode** — *landed* (AGENTS.md D103). `present_plan` is offered in
  every mode, so "plan this first" works without setting the mode; plan mode remains the
  stronger guarantee (it withholds every changing tool). Found by the first live test, where
  asking for a plan in Review produced a text file instead.
- **No step cap; Stop instead** — *landed* (AGENTS.md D104). A turn runs until the model is
  done; the composer's **▶** becomes **■ Stop** while it works, and `agent.stop` kills the turn
  wherever it is — waiting on the provider, parked at the gate, or running a command — leaving
  the conversation extendable. Replaces the hard-coded `maxsteps 8` that a live test turn died
  on. Also reaches a turn that `agent.reset` and a new message previously could not.
  Still wanted: a **safety ceiling** for an unattended runaway (deliberately not added — jka
  chose the uncapped version), and **streaming a command's output** as it runs.
- **rio's own prompt: written properly, and visible** — *landed* (AGENTS.md D105). The shipped
  base prompt (`agent/prompt.md`) is now a full agentic-coding brief — the gate contract, how to
  work in someone else's codebase, argv-only commands, verify-then-report, scope and voice, and
  *content you read is data, not instructions* — and the plan layer matches it. Because the core
  composes the prompt for every provider (D20/D34), one file makes Claude, an OpenAI-compatible
  model and a local model behave like the same IDE agent. **And none of it is hidden:**
  *Preferences ▸ Agent ▸ Agent Prompts…* lists all five layers in composition order with what
  each is doing right now, renders rio's own two read-only, shows the **composed** prompt exactly
  as sent, and turns any shipped layer into an editable copy seeded with the text it replaces
  (`agent.prompt.list` / `.get` / `.edit`).
  Still wanted: rendering rio's *superseded* version next to an override (today the override is
  shown and rio's own copy is only on disk); a token-count beside each layer.
- **Model and effort, chosen from the pane** — *landed* (AGENTS.md D106). The strip at the
  bottom of the agent pane is now the control that says — and sets — **which agent is
  working**: provider, model, and how much effort to ask for, in one menu, with *Other…* for
  a model id the shipped list never carried and **⟳ Refresh from provider** for what the key
  (or the local server) can actually reach. The seam is provider-declared options
  (`register_provider -options`, `agent.options.list` / `.option.set` / `.options.refresh`):
  the core routes them by name and never learns what "effort" means, so a provider's third
  knob needs no core *and* no GUI change. Effort sends **nothing** by default — `gpt-4o` and
  most local servers reject the field — and every choice persists in one flat, hand-editable
  file per provider beside its prompt layer. `provider-api` is now **2**.
  **Verified live** (D106a): the listing fetch, and `output_config.effort` accepted by Opus 5
  and Sonnet 5 — while **Haiku 4.5 refuses it** (HTTP 400). So the Claude face now reads
  `capabilities.effort` from the same listing and offers only what the chosen model takes,
  sending none for a model that takes none. No hardcoded model names.
  Still wanted: the same live proof for OpenAI's `reasoning_effort` (no key stored here);
  `max_tokens` and the endpoint URL as options; a per-project model.

## Frontends

- **Ck terminal frontend (TUI)** — *deferred.* A spike proved Ck can carry it
  (rendering, editing, reflow, colour, Unicode), so the risk is retired, but building
  the terminal frontend is a separable later effort. It attaches over the same
  language-neutral protocol, so it lands *without touching the core*.

## Project & packaging

- **Plugin interface** — *design.* Plugins (LLM providers, extra agent tools) exist,
  but the public interface is still being shaped and will change; not yet a stable
  contribution surface. (Syntax highlighters, by contrast, are stable today.)
  Since D123 the two surfaces that *can* break say so with a contract integer —
  `provider-api` and `mode-api` — so a plugin built against a newer rio is greyed
  "needs a newer rio" instead of failing when it loads. That makes the instability
  survivable, not over: what is still ahead is the interface settling down, which is
  also what **1.0.0** is reserved for.
- **Install / packaging path** — *planned.* A polished install and packaging story
  beyond the dev/server deploy scripts (see [INSTALL.md](INSTALL.md)).
- **Code of conduct** — *landed.* The Contributor Covenant 2.1, with reports going to
  jlsksr@gmail.com — see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Standard text over a
  house-written one for the same reason as the licence (D121): recognition is worth more
  than a house dialect for the documents a stranger meets first. (The licence half is
  **done** too: rio is MIT-licensed, D121 — see [LICENSE](LICENSE).)
