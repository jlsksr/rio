# Changelog

Every notable change to rio — features, improvements and fixes. It is **not** every
commit.

The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and rio's version
is [semver](https://semver.org/) (AGENTS.md **D123**). Each entry cites the design
decision behind it — *Dnn*, written up in [AGENTS.md](AGENTS.md) and filed as a record in
[adr/](adr/) — a representative commit, and the date it landed.

An entry is a change **as it landed**. Where a later decision amends an earlier one, it
gets its own entry and says so, rather than editing the history it changed.

## [0.1.0] — 2026-09-23

Everything below is rio's first release, built between 2026-06-24 and the day it was
tagged.

### Added

- **Named profiles for an agent provider** — keep one configuration for hosted ChatGPT
  and another for the server on your own box, and switch between them in a click. The
  **Profile** row at the top of a provider's settings window switches; **Manage…** makes,
  copies, renames and deletes; the agent strip's menu switches too. Each profile keeps its
  own model, URL, caps **and its own API key**, so moving to a local server never sends a
  hosted vendor's key to your own machine. A first run starts with three — ChatGPT and two
  local examples — written once, so deleting or editing one sticks. An existing setup is
  carried forward as a profile of its own, not replaced. The **extra request JSON** is now
  a file you edit in rio (**Edit…**), read fresh every turn, so it can be pretty-printed
  instead of squeezed onto one line; a file that no longer parses stops the turn and says
  which field, rather than dropping settings you wrote. Profiles are a core capability, so
  any provider can offer them. — *D131 · `de313d6` · 2026-09-23*
- **Run a model of your own** — the OpenAI-compatible provider is configured from the
  GUI: ***Preferences ▸ Agent*** gains a settings window per provider, and for this one it
  takes the server's URL (Ollama, llama.cpp, llama-swap, vLLM, LM Studio), lists what that
  machine actually offers, and holds the caps, the token-cap field and a free-form **extra
  request JSON** for whatever a given server understands. **No API key is needed** for a
  server of your own. Pointing rio at one was documented before this and reachable only by
  editing the extension's Tcl on the core's disk. A thinking model's **reasoning** now
  shows in the chat as an aside, set apart from the answer and never sent back with it, so
  it is not re-billed on the next round-trip. The window renders whatever a provider
  *declares*, so one that grows a setting needs no change to rio. — *D128 · `25c5d5a` ·
  2026-09-22*
- **rio has a version, and every number in the tree has a job** — rio is **0.1.0**.
  *Help ▸ About rio* leads with a *Version* row, both entry points answer `--version`, and
  a `--connect` session can name the core's version as well as its own. The wire
  `protocol`, `provider-api` and the new `mode-api` stay plain integers: a release version
  says *which rio is this*, a contract integer says *can these two halves talk*. —
  *D123 · `0ffca02` · 2026-09-20*
- **An installed extension carries its licence inside it** — every payload rio's own
  extensions ship (the Claude and OpenAI providers, the emacs and vi modes, the night
  theme) opens with the full MIT notice. An installed file lands in a directory shared
  with every other extension, far from any `LICENSE`, so the one copy that travels alone
  says what it is. — *D122 · `72fca4a` · 2026-09-20*
- **rio is MIT-licensed** — `LICENSE` holds the standard text verbatim, README and
  CONTRIBUTING say what it means for a user and for a contributor, and *Help ▸ About rio*
  shows it, so the licence is legible from inside a running rio. One licence covers the
  whole tree: every part of rio is the project's own work. — *D121 · `f4a0a22` ·
  2026-09-20*
- **A repository can be signed, and rio checks it** — a publisher signs one root
  `SHA256SUMS` with `ssh-keygen -Y sign`, and rio verifies the signature, then every file
  it installs against those hashes. A repository's version lines end in one word — *signed*,
  *unsigned*, *can't check* — and a source whose signature is bad is refused outright. It
  makes plain `http://` safe to keep first-class: someone rewriting a payload in flight now
  breaks the signature instead of getting their code installed. — *D118 · `9f17f5c` ·
  2026-09-19*
- **rio has a window and taskbar icon** — Christ the Redeemer, for the name, in seven
  sizes, so the window manager and the taskbar stop falling back to two different generic
  icons. The About box wears it too. With `icons/` missing rio starts exactly as before.
  — *D117 · `1426ad4` · 2026-09-18*
- **A right-click menu everywhere text is shown** — the agent log, the compare panes, the
  git diff and the manual answer a right-click now with *Copy* and *Select All*, the
  entries and read-only texts outside the editor with the cut/copy/paste cluster. The
  commands are Tk's own `<<Copy>>` and its neighbours, so the menu and the keystroke are
  one implementation. — *D115 · `b5219fb` · 2026-09-17*
- **Change with Agent…** — select code, right-click, and give the agent an instruction
  about *that text and only that text*: the scope is enforced by the core, not asked for
  in the prompt. The entry appears only while a real provider is selected, and a
  preference in *Preferences ▸ Agent* hides it entirely for anyone who would rather not
  meet AI in a context menu. — *D113 · `233ed1f` · 2026-09-16*
- **Pick a buffer's language by hand** — ***View ▸ Language…*** opens a picker listing
  every shipped language and every installed syntax extension, so pasted code in an
  untitled buffer, or a file whose name misleads, can be highlighted correctly.
  *Auto-detect* and *Plain Text* head the list; the choice is per buffer and sticks
  through Save As. — *D112 · `2145265` · 2026-09-16*
- **A certificate that doesn't verify can be accepted — that one** — an https repository
  or provider whose certificate fails verification is refused, with the reason and the
  certificate shown and **Go Back** as the default button, the way a browser does it.
  Accepting pins that certificate's SHA-256 fingerprint for that host and port; a
  *different* certificate later is refused and the message says it **changed**. Exceptions
  are reviewable and removable in *Preferences ▸ Network*. — *D111 · `94be0d4` ·
  2026-09-15*
- **The agent refuses https it can't fully verify** — a tcltls older than 1.8 checks a
  certificate's chain but never its host name. On such a core an `https://` provider
  request is now refused before anything is dialled, with a message naming both ways out.
  Plain `http://` — a local Ollama or llama-server — is never gated. — *D110 · `449a24f` ·
  2026-09-15*
- **https repositories, beside http** — an extension repository can be served over https,
  verified against **the host's own CA store** (rio bundles no certificates and never
  will). http stays first-class and unbadged, exactly as in apt; a redirect from https to
  http is refused. One TLS policy in the core now covers the repository fetch and the
  agent's connection alike, which fixed verification on Windows on the way. — *D109 ·
  `1f95dd7` · 2026-09-12*
- **A right-click menu in the editor** — undo and redo, cut/copy/paste, select all, and the
  find cluster — *Find…*, *Replace…*, and a **Search** entry that reads *Search for
  "needle"* when you right-click a word. Clicking inside a selection leaves it alone;
  clicking elsewhere moves the caret there, so Paste lands where you pointed. `Menu` and
  `Shift+F10` open it at the caret. — *D108 · `cc937f1` · 2026-09-12*
- **rio tells you when an extension has an update** — versions are
  [semver](https://semver.org/) and rio orders them: a row that has moved on reads
  `[1.1.0 → 1.2.0]`, one button updates it, another updates everything, and rio can look
  when it starts. An update only ever comes from **the repository you installed from**, and
  nothing is ever installed on its own. — *D107 · `ebb1916` · 2026-09-12*
- **Pick the model, and how hard it thinks** — the strip at the foot of the agent pane
  carries provider, model and effort in one menu, with *Other…* for a model id the shipped
  list never had and **⟳ Refresh from provider** for the models your key can actually
  reach. Anything changed from the default is spelled out in the strip rather than left
  quietly on. — *D106 · `78a3860` · 2026-09-12*
- **No step limit — a Stop button instead** — a turn runs until the model is done, and the
  composer's **▶** becomes **■ Stop** while it works. Stop reaches a turn wherever it is:
  waiting on the provider, parked at an approval, or running a command. — *D104 ·
  `0659ff8` · 2026-09-11*
- **Plan mode — the agent says what it would do, and you decide how it goes** — put the
  agent in **Plan** and it is handed no changing tools at all: it reads, then presents a
  plan rendered where the editor sits. **Edit plan** opens it as an ordinary buffer;
  **Approve ▾** chooses, there and then, whether to review each edit or auto-accept from
  that point. Every plan is filed in the project's `.rio/plans/`, and that file *is* the
  plan you approve. — *D101/D102/D103 · `b01bf98` · 2026-09-11*
- **rio shows its own manual** — a user manual written as topic pages in the source tree,
  opened inside rio with **`F1`**: contents on the left, the page rendered on the right,
  with links and `#anchor` jumps you can click and Back/Forward behind them. A **Find** box
  turns the contents into the sections that mention your word. — *D91/D99/D100 · `ea490eb`
  · 2026-09-11*
- **Discard, everywhere** — the file tree carries *Discard Changes…* beside the git pane's
  row menu, and the git header grows a **↩** while anything is changed: throw away the
  whole project's edits at once. Both confirm first, and neither touches ignored files. —
  *D93 · `d70b9c2` · 2026-09-10*
- **rio reopens the folder you had open** — launching with no arguments comes back to your
  last project, with its files, its active tab and the **tree's unfolded shape** — that one
  lives with the project, so it follows onto a remote host. A folder that has since
  vanished is dropped quietly. — *D88/D89 · `609e925` · 2026-09-09*
- **Browse your project as an unfoldable tree** — the Files pane is rooted at your project:
  click a folder's arrow (or double-click its name) and it unfolds in place, several levels
  at once, with the git-status flags riding along at every depth. — *D87 · `be43197` ·
  2026-09-09*
- **Drag a file onto the window to open it** — grab files or whole folders in your OS file
  manager and drop them anywhere on the rio window. It rides on the optional `tkdnd`
  extension; without it rio runs fine and drag-to-open simply stays off. — *D86 ·
  `ed682cd` · 2026-09-09*
- **Trust a command so it stops asking** — the approve bar offers **Always allow**:
  remember the **program** (every `pytest` from now on) or that exact command, scoped to
  all projects, this project, or only while a particular model runs. It is an opt-in list
  *you* write, managed under *Preferences ▸ Agent ▸ Allowed commands…*, and a trusted
  command is still run the safe way — no shell, confined to your project, time-boxed. —
  *D84 · `e566586` · 2026-09-09*
- **The agent can run commands** — ask it to run your tests, a linter or a build and it
  proposes the exact command; you Approve or Reject before anything runs. A command
  **always** waits for you, even with *Auto-accept edits* on. — *D83 · `9f6a688` ·
  2026-09-09*
- **The agent's "working" indicator** — the chat status line cycles vintage loading
  messages while the agent thinks, so a wait never looks like a freeze. — *D82 · `946e6ae`
  · 2026-09-09*
- **Longer commit messages** — the Git pane's commit box has a **＋** for a multi-line
  description under the summary line. — *D81 · `e7e2f43` · 2026-09-08*
- **Discard your changes** — right-click a changed file in the Git pane: **Discard
  Changes…** returns a tracked file to its last committed version, **Delete…** removes a
  brand-new one, each behind a one-click confirm. — *D80 · `0a82d64` · 2026-09-08*
- **Per-provider agent instructions** — instructions that apply only while a particular
  provider is running, alongside the all-projects and per-project layers. — *D79 ·
  `a66c737` · 2026-09-08*
- **Help ▸ About rio** — a Help menu with an About window showing the build's commit id and
  date. — *D76 · `658df39` · 2026-09-08*
- **Compare against an open tab** — Compare becomes its own top-level menu, and any open
  tab can be diffed against the current file through a shared buffer picker. — *D73/D74 ·
  `ac5242d` · 2026-09-08*
- **Anonymous workspace** — opening loose files with no project is a real, resumable
  session: reopen rio and the same files come back. — *D72 · `e912cb8` · 2026-09-08*
- **Relative line numbers** — a hybrid vim-style gutter modifier: the current line shows
  its absolute number, the rest their distance from it. — *D71 · `e7f08f3` · 2026-09-05*
- **A home for the agent's prompts** — the agent's system prompt ships as an editable
  `agent/prompt.md`, with an optional per-project `.rio/agent.md` layer on top. — *D70 ·
  `6d1e38f` · 2026-09-04*
- **A second LLM provider (OpenAI-compatible)** — talk to hosted ChatGPT, or point its base
  URL at a local OpenAI-compatible server (Ollama, llama-server, …) to run a local model.
  — *D65 · `615172b` · 2026-09-04*
- **Current-line highlight** — the caret's line is highlighted, on by default and
  toggleable. — *D60 · `a9204a9` · 2026-09-04*
- **Central Preferences window** — one window gathers the settings that were scattered
  across menus; it owns no state of its own. — *D58 · `b7650f5` · 2026-09-03*
- **Tab-strip overflow handling** — when tabs outrun the strip, page them behind ◂ ▸ arrows
  or wrap them onto several rows, with a Switch-to-Tab picker that lists them all. — *D57 ·
  `bba3078` · 2026-09-03*
- **Editor font picker + zoom** — choose the editor font family and size, and zoom in and
  out, as a user override layered over the theme. — *D56 · `38501a3` · 2026-09-03*
- **Per-pane show/hide** — every tool pane can be hidden entirely, down to a bare editor; a
  dock collapses when its last pane goes. — *D35 · `eea9676` · 2026-08-20*
- **Dockable tool-window system** — Files / Git / Agent / Search sit in left, right and
  bottom docks with host-owned tab strips; relocate a pane by right-click *Move to* or by
  dragging its tab. — *D35 · `48f8656` · 2026-08-20*
- **Search panel** — find-in-files and open-buffer search unified in one bottom panel, with
  replace across scopes and regex on every surface. — *D52 · `34d8b6c` · 2026-08-19*
- **Find in Files** — a core `project.search` with a bottom results panel, a whole-word
  option and per-hit highlighting. — *D51 · `25a752f` · 2026-08-19*
- **Cursor position** — a live Ln/Col indicator in the status bar. — *D50 · `2ce889e` ·
  2026-08-19*
- **Line-number gutter** — an optional gutter down each editor group. — *D49 · `acefe91` ·
  2026-08-19*
- **File management** — New / Rename / Delete from the file pane's context menus. — *D48 ·
  `5315a28` · 2026-08-18*
- **Syntax highlighting reaches 33 languages** — Ruby, SQL, YAML, TOML, Java, Kotlin,
  Swift, Scala, TypeScript, XML, INI, Makefile, Dockerfile, Batch, PowerShell, awk and sed,
  with whole-name registry matching. — *D32/D46 · `8e8dd83` · 2026-08-10*
- **Git commit from the GUI** — an auto-showing commit bar, and the first inline pane
  input. — *D45 · `76bea36` · 2026-08-07*
- **Git write operations** — stage / unstage / track from right-click menus on the file and
  git panes. — *D44 · `3df70cd` · 2026-08-07*
- **Column / block editing** — a Notepad++-style vertical, multi-line cursor. — *D40 ·
  `99a07f3` · 2026-07-23*
- **Extension repositories** — install highlighters, modes and themes from plain-`http://`
  repositories you add yourself (the apt-sources model: no store, no central index), with
  an Extensions window and provenance tracking. — *D39 · `e0f59b0` · 2026-07-22*
- **Editing modes** — Windows / Emacs / Vi as a bind-tag layer. — *D38 · `ea94992` ·
  2026-07-12*
- **Find / Replace** — a search engine in the core with an in-buffer find bar. — *D36 ·
  `a8bc970` · 2026-07-12*
- **Dock-site system (first cut)** — tool windows get a real dock instead of
  chat-as-buffer. — *D35 · `16ab10a` · 2026-07-12*
- **Configurable keybindings** — every shortcut is one data table, remappable live in a
  press-to-capture editor or by hand in `keys.json`. — *D23 · `a0cb75b` · 2026-07-08*
- **Split editor** — two buffers side by side in independent groups; drag tabs to reorder
  within a group or move one across, plus a right-click tab menu. — *D33 · `7bcfe78` ·
  2026-07-06*
- **Syntax highlighting engine** — swappable per-line tokenisers and the first 16 languages
  (HTML, CSS, JS, Perl, Tcl, shell, Markdown, PHP, Python, Lua, C, C#, C++, Go, Rust,
  JSON). — *D32 · `5195c91` · 2026-07-01*
- **Sessions & preferences** — resume the open files, the active tab and your view
  preferences; a remote session resumes too. — *D31 · `2bd6372` · 2026-07-01*
- **Remote from a running GUI** — *File ▸ Connect to Remote Core…*, with point-and-click
  remote file browsing. — *D30 · `4bbda06` · 2026-07-01*
- **Edit over a remote core** — the GUI as a socket client, failing gracefully when the
  core is unreachable, plus the slim `rio-server-deploy.sh`. — *D29 · `c4f6ddf` ·
  2026-06-30*
- **Compare / diff view** — a side-by-side diff of two documents, added and removed lines
  coloured and aligned. — *D28 · `086654f` · 2026-06-29*
- **AI agent** — a streaming `agent.*` protocol and chat pane, the Claude provider over the
  official Anthropic API, read-only file tools, and a propose-and-approve edit gate: reads
  run freely, every write waits for you. — *D26 · `48f58f9` · 2026-06-28*
- **Files & git side dock** — a resizable dock hosting the file browser and a git
  status / diff / log pane. — *D7 · `21cc63a` · 2026-06-27*
- **Theming as plain data** — semantic, live-switchable themes that execute no code:
  default, Solarized Dark/Light, Plan 9 Acme. — *D24 · `d59e105` · 2026-06-26*
- **Core foundation** — the UI-less document model and dispatch, `buffer.*` / `fs.*` ops
  with encoding and LF/CRLF preservation, per-buffer undo/redo, a socket transport, and
  `session.hello` negotiation. — *D22 · `0199abc` · 2026-06-25*
- **A real Tk frontend**, wired to the core across the protocol seam. — *`17cbadd` ·
  2026-06-25*
- **Project start** — the AGENTS.md decision log and the initial design docs, followed the
  next day by the protocol-seam spike that proved the core⟷frontend bet. — *`7a97d46` ·
  2026-06-24*

### Changed

- **The Extensions window says which repository it means** — a source is now named by
  its whole URL wherever you are choosing between sources: the version lines in the
  detail pane, the *Update All* confirmation and the start-up update notice. It used to
  print only the host, so `http://host/rio` and `https://host/rio` — which rio keeps as
  two sources in the list and one repository for updates — looked identical on the line
  where you pick between them. Prose about a repository still names its host. The window's
  status line is now a proper **status bar**, a strip along the bottom edge below the
  buttons, instead of a label sharing the button row where what the window had just done
  read as one more line of the pane above it. — *D39/D130 · `26b12ea` · 2026-09-23*
- **Every extension configures itself, from a menu of its own** — there is a new
  top-level ***Extensions*** menu, between Settings and Help. It leads with
  ***Extensions ▸ Browse…*** (the installer, which leaves the Settings menu) and then
  lists one entry per installed extension that has anything to set. A provider's **API
  key is now a row in that provider's own window**, beside its model and its endpoint,
  instead of a separate dialog — so everything belonging to one provider is in one place,
  and *Preferences ▸ Agent* keeps only rio's own agent settings instead of growing two
  buttons per provider installed. rio's settings *about* extensions — update checking,
  repositories, signing keys — stay in *Preferences ▸ Extensions*. Reverses where D128
  put this. — *D130 · `67a4c6c` · 2026-09-23*
- **Installing rio is one script named after your system, and leaves you a `rio` you can
  launch** — the setup scripts are now `install-unix.sh` (Linux, the BSDs, macOS),
  `install-windows.ps1` and `install-server.sh`, replacing two that said *dev-deploy* and
  three whose platform was visible only in the file extension. The POSIX one no longer
  stops at installing packages: it adds a `rio` command and an entry with rio's icon in
  your application menu, under `~/.local`, needing no root and removable with
  `--uninstall`. On Windows the Start Menu and Desktop shortcuts are now made by default
  and carry rio's own icon. **macOS is newly attempted** — the script knows Homebrew, and
  knows to use its Tcl rather than the ancient one Apple ships — but nobody has yet run
  rio on a Mac, so it says so and asks for a report. — *D129 · `5b4fbeb` · 2026-09-22*
- **The last three passes over a big file are gone too** — continues D126 with the work it
  left on the table. rio no longer walks a document twice to see whether it uses CRLF line
  endings (the normalisation it does next already knows, and a file with none needs no
  counting at all), no longer tests every character of every value it sends against
  twenty-nine control characters a document never contains, and pulls the highlighter's
  scan out of the editor in chunks rather than a line at a time. That scan also stops
  keeping a separate copy of the same handful of states for every line: on an 8 MB file,
  36 MB of memory down to 9. — *D126 · `668b47d` · 2026-09-21*
- **Big files open about eight times faster, and the limit moves to 64 MB** — amends
  D125, which made a file over 8 MB a question. The 8 was never about how big a file is;
  it was the cost of three whole-file passes rio did not need to make. Deciding UTF-8 by
  re-encoding and comparing instead of walking every byte in Tcl, highlighting the visible
  window instead of the whole buffer, and pulling the document over the channel in chunks
  (tcllib's JSON parser is quadratic in the length of one string) took an 8 MB open from
  ~13 seconds to ~1.6, *with* syntax highlighting rather than stripped to Plain Text. The
  question is unchanged in shape and still asked at every door — only the number moved. —
  *D126 · `5dcf9ec` · 2026-09-20*
- **rio ships only artwork it can pass on** — the stock icons rio wore since D117 are
  removed rather than re-credited: what their licence allowed downstream of a `git clone`
  was not clear enough to ship. The replacement is the project's own artwork, so rio may
  ship it and anyone may redistribute it. — *D120 · `a9b21c2` · 2026-09-20*
- **A signing key is trusted when you say so** — amends D118's trust-on-first-use, which
  recorded a repository's key silently the first time it verified. rio now shows the
  fingerprint and waits for a **Trust** the way `ssh` does, so a key that arrives first can
  no longer win permanently and invisibly. — *D119 · `7c98705` · 2026-09-19*
- **A missing dependency says which package to install** — `package require json` on a host
  without tcllib used to be a Tcl stack trace (and, under `wish` on Windows, a modal dialog
  blocking start-up). rio now names the OS package to install — INSTALL.md's own words —
  and exits. — *D116 · `fceeb93` · 2026-09-17*
- **One core-wide switch for https without host-name checks** — amends D110 and D109: the
  repository fetch and the agent now ask the same question on a tcltls older than 1.8, and
  the user can opt out for both in a new **Network** category in Preferences, where
  *Accepted certificates…* also moved. Unchecked https is never weaker than the plain http
  repositories rio already accepts. — *D114 · `18a5f29` · 2026-09-17*
- **rio's own instructions to the agent, in the open** — the prompt rio sends on your
  behalf is a proper brief on agentic coding, and none of it is hidden: *Preferences ▸
  Agent ▸ Agent Prompts…* lists all five layers in composition order, says what each is
  doing right now, and shows the **composed** prompt exactly as the model receives it. One
  click turns any shipped layer into your own editable copy. — *D105 · `f06ae0f` ·
  2026-09-11*
- **Undo takes back a word, not a keystroke** — a run of typing coalesces into one undo
  step, sealing at a blank. Enter always stands alone, and a paste or an agent edit is
  still its own step. — *D90 · `adf628d` · 2026-09-10*
- **Agent settings gathered in one place** — the top-level *Settings* menu keeps only the
  two quick switches you flip mid-task; the agent's real configuration — key, prompts,
  trusted commands — moved into the Preferences window's Agent pane. — *D85 · `5205f6c` ·
  2026-09-09*
- **Open several files at once** — the Open dialog takes a Ctrl/Shift multi-selection and
  opens every picked file. — *D77 · `ef53df6` · 2026-09-08*
- **A Find menu** — the search cluster (Find, Replace, Find in Files…) gets its own
  top-level menu. — *D75 · `3424c34` · 2026-09-08*
- **LLM providers are installable extensions** — Claude and OpenAI-compatible both install
  from an extension repository like anything else; the core ships only the offline `echo`
  stub. — *D66/D69 · `c15ae1c` · 2026-09-04*
- **Extensions… moves to Settings**, beside Preferences…, rather than sitting in the View
  menu. — *D67 · `13b77fc` · 2026-09-04*
- **The View menu fits on screen** — grouped into submenus so it never runs off a short
  display. — *D64 · `223fa89` · 2026-09-04*
- **Tooltips on glyph controls** — the bare-glyph header buttons (⟳, hidden-files, …) name
  what they do on hover. — *D63 · `d45c215` · 2026-09-04*
- **Hide dotfiles** — the Files pane hides them by default, like `ls`, with a ◉/◌ toggle in
  its header. — *D62 · `bcd591b` · 2026-09-04*
- **Click a gutter number** to select its whole line, drag to extend the selection. — *D61 ·
  `bb55728` · 2026-09-04*
- **Column-editing caret polish** — the multi-line block caret is a thin blinking bar on
  every line, and the toggle is greyed out except in Windows editing mode. — *D40 ·
  `5a95e65` · 2026-08-20*
- **File-pane auto-refresh** — the tree updates when files change on disk outside a buffer
  (an agent write, say), with a manual ⟳ and an on-focus refresh. — *D47 · `5728334` ·
  2026-08-18*
- **Rich file & git panes** — both become text-widget rich-lists, and the file pane flags
  each file's git state. — *D42/D43 · `3cde0a4` · 2026-08-06*
- **Emacs & Vi unbundled as extensions** — the core ships Windows mode only; the other two
  install from a repository like any other extension. — *D41 · `c1be851` · 2026-08-03*
- **Indent Wrapped Lines** — align a paragraph's wrapped rows under its own indent; Tab
  block-indents the selection in Windows mode. — *`a0b323d` · 2026-07-23*
- **Monochrome-glyph iconography** — the modified dot, the find arrows, send and refresh
  become Unicode glyphs rather than images. — *D27 · `2019c19` · 2026-07-23*
- **The agent's system prompt becomes core-owned** and provider-agnostic, layerable per
  project via `.rio/agent.md`. — *D34 · `8378cf4` · 2026-07-08*
- **One channel transport** — the GUI always spawns or attaches a core over a channel (pipe
  locally, socket remotely), the in-process path retired; the agent moved onto the channel
  too, so a remote core keeps your key and its HTTPS server-side. — *D30 · `ff4dc93` ·
  2026-06-30*

### Fixed

- **A headless test run can no longer take your keyboard** — running the GUI suites on the
  display you are working at, rio's off-screen test window was mapped like any other, so a
  click-to-focus window manager gave it the input focus and the next key you pressed landed
  in the buffer a test was about to check. It made `context_menu.tcl` fail about one run in
  twelve, with a different stray letter each time. The window is now withdrawn before
  anything can map it, and the one map it still needs — to lay out the panes — happens
  where the window manager cannot see it. A run that holds the X focus at all now fails and
  says so. — *D127 · `7ce1c9d` · 2026-09-21*
- **Opening a huge or binary file no longer freezes rio** — a stray double-click on a
  build log, a core dump or an ELF binary used to read the whole thing, decode it and hand
  it to the editor, which took seconds to minutes and answered nothing in the meantime (in
  a `--connect` session, for every frontend on that core). rio now looks before it reads:
  a file over 8 MB, or one that looks binary, is a question — *"core.dump is 1.2 GB —
  large enough that opening it may make rio slow to respond. Open it anyway?"* — and a
  file opened anyway starts as Plain Text, with *View ▸ Language…* to turn highlighting
  back on. Project search's own size-and-binary rule is now the same one implementation.
  — *D125 · `bae49b6` · 2026-09-20*
- **Installing an extension no longer mangles it** — every download from a repository was
  decoded twice, so any non-ASCII character arrived corrupted (an em-dash became `â`).
  Fixed in the fetch; a re-install repairs what is already on disk. — *D106e · `af9dfd8` ·
  2026-09-12*
- **A file in a brand-new folder gets its own door** — `git status` collapses a wholly
  untracked directory into one line, so a new file in a new folder had no row in the git
  pane and no git entries in the tree's menu. The tree now offers **Track (git add)** on
  the file itself. — *D98 · `0f401d3` · 2026-09-11*
- **Discarding a rename puts the file back under its old name** — discard handled only the
  new name, leaving a deleted old file beside an untracked new one. Both names are the
  change now. — *D97 · `fef1999` · 2026-09-11*
- **A tab notices when its file changed underneath it** — after a `git pull`, a build or
  rio's own discard, an open tab went on showing the old text and a later Save wrote it
  back over the new content. A clean buffer now reloads quietly, a modified one asks and
  defaults to keeping your edits, and a file deleted on disk asks whether to keep the
  buffer open. The check runs in the core, so it is just as true over a remote one. — *D94
  · `9ce1b61` · 2026-09-10*
- **The theme list can't outgrow the screen** — an over-tall Tk menu on X11 can close
  itself on a mid-list hover, so both doors onto the theme list became the bounded picker
  dialog, which scrolls inside a fixed frame. — *D92 · `cf55fe0` · 2026-09-10*
- **Multi-line tabs, tightened** — each row packs its tabs at their natural width and
  justifies to fill the strip, so a short tab no longer inherits a long tab's column. —
  *D78 · `e5d12da` · 2026-09-08*
- **Windows support** — source files are read as UTF-8 everywhere (no more mojibake
  glyphs), and the core answers host questions so a remote frontend never guesses the wrong
  path rules. — *D54/D55 · `508f4e9` · 2026-09-03*
- **Line-number gutter repaint** — the gutter repaints on edits that add or remove lines and
  on tab switches, not only when the view scrolls. — *D49 · `cf424b6` · 2026-08-20*
- **Stale-link watchdog** — a dead SSH tunnel is detected in seconds, not minutes. — *D37 ·
  `eed9bfc` · 2026-07-12*

[0.1.0]: https://github.com/jlsksr/rio/releases/tag/v0.1.0
