# Contributing to rio

rio is a small, cross-platform IDE: a fast, no-nonsense text editor with proper
git and AI-agent support — a desktop GUI today, with a terminal frontend planned
(both over one shared core). If you like editors that stay out of your way — and
software whose source you can actually sit down and read — you'll feel at home here.

This guide is for programmers who want to hack on rio itself. Welcome; we're glad
you're here.

> **Heads-up:** rio is in early days. The UI-less core does real work now —
> open/save with encoding and line-ending preservation, range-based editing, and
> undo/redo — and there's a minimal but real Tk editor (`rio-gui`) wired on top of
> it. It's far from a finished IDE, but you can open a file, edit it, undo, and
> save. The architecture is settled and there are real tests to run (below). The
> full reasoning behind how rio is put together is in [AGENTS.md](AGENTS.md).

## What rio cares about

A few values, so you know the kind of changes that fit:

- **Small and simple.** rio is meant to be understood by one person in an
  afternoon. Resist feature creep; the goal isn't to out-feature the big IDEs.
- **Readable beats clever.** Clear code that the next person can follow wins over
  a tighter trick. Comment where it helps, name things well.
- **Efficient, in the 90s-productivity sense** — quick, sharp, no wasted motion
  for the user.
- **Cross-platform, honestly.** Linux, the BSDs, and Windows; a GUI and a
  terminal version that share the same brain.

## How the code is laid out

rio is split into three kinds of thing, and knowing the split tells you where
your code belongs:

- **The core** holds all the real logic — open files, editing, undo, git, the
  agent machinery, project state. It has *no* user interface and could run on its
  own. This is where most of the code lives.
- **The frontends** are the desktop GUI (built with Tk) and the terminal UI
  (built with Ck, a curses toolkit). They're deliberately thin: they draw what
  the core tells them and send back what you type. They don't make decisions.
- **Plugins** are separate programs that talk to the core. This is how things
  like LLM providers (Claude, a local model) and other extensions hook in,
  without bloating the core.

**Rule of thumb:** if you're writing actual logic, it almost certainly belongs in
the core. Keep the frontends dumb.

## A few house rules

- **Logic in the core, not the UI.** If you're tempted to put behaviour in the
  GUI or TUI, it probably wants to be in the core instead.
- **The core owns your open files; the frontends are just windows onto them.**
  Edits flow as commands into the core, and the views refresh from it.
- **Keep the GUI and the terminal version in step.** Shared behaviour, different
  drawing — a feature shouldn't work in one and not the other.
- **Reach for a plugin before growing the core.** Anything beyond the essentials
  is a good candidate to live outside.
- **Tcl all the way down.** Core and GUI are Tcl/Tk; the (deferred) terminal
  frontend is Ck. rio uses **no Python** — not even for a throwaway script.
- **Headless code stays Tk-free and exits explicitly.** The core, the tests, the
  server — anything without a window — must not `package require Tk` (it makes a
  bare `tclsh` hang at EOF) and should `exit` rather than fall into the event loop.
- **Match the style of the code around you.**

The *why* behind all of these is in [AGENTS.md](AGENTS.md) if you're curious.

## Extending rio

rio is meant to be extended through plugins — small separate programs that speak
rio's protocol (in whatever language you like), or lightweight ones running
in-process. LLM providers and extra agent tools are built this way.

The plugin interface is still being designed and *will* change, so it's not the
place to start contributing yet. If you want to follow or shape that design, it's
covered in [AGENTS.md](AGENTS.md).

**Syntax highlighters, though, are a stable extension point you can use today.** A
highlighter is a small, self-contained file in `syntax/` — pure Tcl, no Tk, no
external packages — that turns text into coloured spans; the frontend paints them
with the active theme's colours (design: [AGENTS.md](AGENTS.md) D32). To add a
language, copy `syntax/html.tcl` as a template: write a per-line **scanner**,
`scan {line state param}`, that returns `{spans nextstate nextparam}` — the coloured
column ranges for that one line (a flat `c0 c1 type …` list, `type` from the fixed
vocabulary in `syntax/registry.tcl`) plus the tokeniser state *entering the next
line* — and `register` it at the bottom: a human-readable language name (shown in
the status bar, e.g. `HTML`), the file extensions it claims, and the scanner. Working one line at
a time with a carried-over state is what makes multi-line constructs (open comments,
here-docs) colour correctly *and* lets the editor re-highlight incrementally as you
type; entering the first line the state is the empty pair (`rio::syntax::start`), so a
scanner just treats state `""` as "start of text". Because a highlighter is picked by
extension and a later registration wins, you can **replace** a shipped one without
editing it: drop your version in `~/.config/rio/syntax/` and it shadows the built-in.
Themes colour the token types through their `syntax.*` roles, so nothing is hard-coded
to a palette.

**Editing modes are the second stable extension point** (design:
[AGENTS.md](AGENTS.md) D38). A mode decides what the keyboard does inside the text
area — the core ships only `windows` in `modes/`; `emacs` and `vi` ride the same
contract as **installable extensions** (D41, `extensions/`), which is the proof that
the seam holds. Yours works the way all three do: one self-registering Tcl file.
Write an `attach` that installs `bind <tag> …` bindings (end a binding in `break` to
beat Tk's Text defaults; leave it off to fall through to them) and a `detach` that
clears any state you keep, then
`rio::modes::register name label attach detach` at the bottom. Drop the file in
`~/.config/rio/modes/` — it appears in *Settings ▸ Editing Mode* automatically, and
registering an existing name replaces the shipped mode. Two rules of the road: the
app shortcuts always fire before your mode's keys, and edits must go through the
widget your binding receives (`%W`, the group's proxy) — that's what keeps a mode
working against local and remote cores alike. [extensions/vi/vi.tcl](extensions/vi/vi.tcl)
is the worked example of per-editor state; [extensions/emacs/emacs.tcl](extensions/emacs/emacs.tcl)
is the minimal one — and each sits beside the `rio-extension.conf` that publishes it,
so they double as worked examples of the next section.

And once you've written a highlighter, a mode, or a theme, you can **publish
it from your own web server** — no store, no account. That's the next section.

## Extension repositories

Syntax highlighters, editing modes, and themes don't have to sit in your own
config dir — they can be **shared**. rio's distribution model is deliberately
the apt-sources one: there is **no central index, no account, no platform**. A
repository is nothing but a **plain `http://`-reachable directory** with a
couple of text files in it; every rio user who adds your URL under
*Settings ▸ Extensions… ▸ Repositories…* can browse and install what you put
there. Copying files into a webdir is the whole publishing story — and it will
still work in thirty years, the way OpenBSD's plain-http mirrors do.

This section is the spec: everything you need to publish extensions from your
own web server, with no other help.

### Hosting a repository

Give any directory your web server serves this shape — shown here as a real,
complete repository carrying one theme:

    yourserver.example/rio/
    ├── rio-repository.conf         # the marker: this dir IS a rio repository
    ├── index                       # what's in it (optional, see below)
    └── night-theme/                # one directory per extension
        ├── rio-extension.conf      # the extension's manifest
        └── night.theme             # its payload file(s)

`rio-repository.conf` — **required**. Its presence is what makes the directory
a repository; a source without a parseable one is refused ("not a rio
repository"):

    name = jka's rio extensions
    description = extensions I use and share
    maintainer = jka

`index` — the extension list: one subdirectory name per line, `#` comments and
blank lines allowed:

    # what this repository carries
    night-theme

You may omit `index` entirely if your server generates directory listings
(autoindex): rio falls back to parsing the listing, and the Apache, nginx, and
OpenBSD `httpd` formats are all understood. An explicit `index` is still the
sturdier choice — it works with listings disabled and lets you keep a
directory staged but unpublished.

`night-theme/rio-extension.conf` — the manifest, which is what the Extensions
window shows:

    name = night
    kind = theme
    version = 1.0
    author = jka
    description = a very dark theme
    files = night.theme

`night-theme/night.theme` — the payload: exactly the file a user could have
dropped into a config dir by hand:

    base = solarized-dark

    [colors]
    editor.bg = #101018

That's the whole thing. No registration, no upload step — the files under your
URL *are* the repository.

### The formats, precisely

All three files use rio's conf format (AGENTS.md D21): `key = value` lines,
`[section]` headers, `#` comments, UTF-8 — **data, parsed and never executed**.

`rio-repository.conf`: `name` is required (shown as the repository's name);
`description` and `maintainer` are optional and shown alongside.

`rio-extension.conf`, per extension directory:

| key           | required | meaning                                                        |
| ------------- | -------- | -------------------------------------------------------------- |
| `name`        | yes      | the extension's name — users see it as *kind/name*             |
| `kind`        | yes      | what it is: `syntax`, `mode`, `theme`, or `provider` today (open — below) |
| `version`     | yes      | an **opaque string** shown to users (`1.0`, `2026-07-17`, …) — rio displays it, never compares it |
| `files`       | yes      | the payload filename(s), space-separated, beside the manifest  |
| `author`      | shown    | your name or handle — displayed with every variant             |
| `description` | shown    | one line about the extension                                   |
| `provider-api`| provider | (`kind = provider` only) the integer contract version your provider targets — see below |
| `entry`       | provider | (`kind = provider` only) which payload file the core sources to load it |

Rules of the tree:

- **One extension per directory.** Any number of payload files, but **no
  subdirectories** inside an extension (v1).
- **The safe-name rule.** Every name rio takes from a repository — an
  extension directory, `name`, `kind`, each entry of `files` — must match
  `^[A-Za-z0-9][A-Za-z0-9._-]*$`. That's a format rule, not a style tip: these
  names get joined into URLs and into file paths on the user's machine, and
  this one rule is what makes `../`, absolute paths, percent-encoding, and
  spaces impossible by construction. Anything failing it is skipped.
- **Plain `http://` only.** rio implements no TLS of its own. If your server
  is https-only, serve the repository from a plain-http host or front it with
  a proxy (relayd, nginx); repository TLS is a roadmap item, and the trust
  section below is honest about what https would and wouldn't buy here.
- Payloads are **text** (Tcl source, theme files); fetches are capped at 2 MB.

What each kind installs as:

- `syntax` — a highlighter module (the scanner contract above) → the user's
  `~/.config/rio/syntax/`, exactly like a hand-dropped file.
- `mode` — an editing mode (the modes contract above) → `~/.config/rio/modes/`.
- `theme` — a theme file → the **core's** user themes dir, via the protocol
  (`theme.put`) — themes are read by the core, which may be a remote box.
- `provider` — an agent provider (a second LLM service for the chat/agent) →
  the **core's** provider store, via the protocol (`provider.put`). See below.

### Publishing an agent provider (`kind = provider`)

A provider is the highest-trust kind, so it works a little differently — worth
understanding before you publish one:

- **It runs in the core, and activates on restart.** A provider is Tcl the core
  *sources* (not GUI drop-in code, not data). Installing it writes your files into
  the core's provider store; it becomes live the next time the core starts — the
  Extensions window tells the user to restart. A provider is one directory with the
  manifest and your `.tcl` payloads (no subdirectories, v1); the core sources the
  file named by `entry`, which should register the provider.
- **Write against `provider-api`.** Declare the contract version you built for
  (`provider-api = 1` today). The core loads the API surface — `rio::agent::register_provider`
  (with `-label`, `-signup`, and a `-key` capability), the provider proc contract
  `{conversation tools system post}` with its `delta` / `tool` / `done` / `error`
  callbacks, and the runtime helpers `rio::llm::http::stream`,
  `rio::llm::jstr` / `rio::llm::obj_json`, and `rio::secret::*` — *before* your code,
  so you ship no copy of it. A rio that implements an older `provider-api` than you
  declare lists your provider greyed ("needs a newer rio") and won't install it.
  ([extensions/openai/](extensions/openai/) is a complete worked example — the
  OpenAI-compatible provider ships exactly this way.)
- **The user is warned, specifically.** Because your code runs in the core (which
  may be a shared or remote host), can be handed the API key the user enters for it,
  and makes network calls with it, the install dialog says so and names your source.
  Publish from a source people can trust with their model credentials.

### The forward-compatibility contract

Two guarantees make a repository you publish today durable:

- **Unknown keys are ignored.** rio reads the keys it knows and skips the
  rest. A future rio adding manifest fields (entry points, declared
  permissions — AGENTS.md D19) won't break the manifest you wrote today, and
  you may carry extra keys of your own without harming older rios.
- **Unknown kinds are listed, never errors.** The `kind` vocabulary is open on
  purpose: the extension system has to carry future, community-contributed
  kinds nobody has thought of yet — a deploy tool, a protocol bridge, whatever
  comes. A rio that doesn't know a kind still lists the extension, greyed,
  marked "needs a newer rio"; it just won't install it. Only the
  kind→install-target mapping above is version-specific.

### Testing your repository

Add your own URL in *Settings ▸ Extensions… ▸ Repositories…* and watch the scan:
everything you published should list, and installing your own extension is the
honest end-to-end test. Without rio at hand, two curl one-liners tell you most
of it:

    curl http://yourserver.example/rio/rio-repository.conf   # does the marker parse?
    curl http://yourserver.example/rio/index                 # does it list your dirs?

### Updating & removing

To ship a new version, update the payload files and **bump `version =`**. It's
an opaque label, so date stamps serve as well as semvers. Users see your new
version listed beside the one they installed and re-install to update — rio
never auto-updates. To retire an extension, delete its directory (and its
`index` line): it unlists, while existing installs keep working and stay
removable — each user's rio remembers what it installed, and from where.

### Trust, honestly

- Installing a **syntax highlighter or an editing mode is installing Tcl code
  that runs inside the user's editor**, with the user's permissions. rio says
  exactly that at install time, next to your source URL. There is no sandbox
  and no signing yet (roadmap): **your URL is your reputation**, and a user's
  sources list is their trust list — exactly like apt's.
- A **theme is data** — parsed, validated, never executed — and the consent
  dialog says that too.
- Every installed extension is **marked with its provenance** (source URL +
  version). When two repositories offer the same name, rio lists both
  variants, each labelled with author and source, and the user chooses.
  Nothing is resolved by authority, because there is no authority.

**`.well-known/rio-repository`** — specced now, consumed by a future rio: a
plain-text file at your **host root**
(`http://yourserver.example/.well-known/rio-repository`) listing, one per
line, the repository paths on that host the operator vouches for:

    /rio/

A later rio can show a "host-validated" badge from it — and it's the natural
hook for an official-approval marking after that. Publishing it today costs
one static file and makes your repository ready for both.

(The design rationale for all of this — and why it is emphatically *not* a
marketplace — is AGENTS.md D39.)

## Getting started

rio is written in Tcl/Tk, so there's nothing to compile — but you do need the
runtime in place: `tclsh` and Tk, plus a couple of small libraries — `tcltls`
(for the agent's HTTPS) and `tcllib` (for JSON) — and `git`.

The quickest way is the setup script in the repo root:

    ./rio-dev-deploy.sh                # install the core toolchain
    ./rio-dev-deploy.sh --verify-only  # just check what you already have

It works on Debian/Ubuntu, Alpine, and OpenBSD, and finishes by loading the
pieces through `tclsh` so you know they actually work. If you also want to hack
on the terminal version, add `--with-ck` to build the curses toolkit from
source — otherwise skip it; the GUI doesn't need it.

To run only the **headless core** on a remote box (server mode, no GUI), there's
a slimmer sibling — `./rio-server-deploy.sh` installs `tclsh` + `tcllib` + `tcl-tls`
(Tk-free, but the agent runs in the core now, so its Claude HTTPS needs TLS here),
and verifies it by binding a throwaway socket.

Full install & deployment details — local vs. remote, the SSH-tunnel recipe, where
the agent's key lives, and troubleshooting — live in [INSTALL.md](INSTALL.md).

With the toolchain in place you can run the GUI editor — it spawns its own
private core as a child process and talks to it over a pipe, so there's nothing
else to start:

    wish rio-gui/rio-gui.tcl [file ...]

Open files with Ctrl+O (each lands in its own tab), New with Ctrl+N, switch tabs
with Ctrl+Tab, close one with Ctrl+W, save with Ctrl+S, undo/redo with Ctrl+Z /
Ctrl+Shift+Z — all remappable in `keys.json` (a single table; see
[docs/keyboard.md](docs/keyboard.md)). *View ▸ Theme…* switches the colour theme
live (default or the shipped examples in `themes/` — Solarized Dark/Light and Plan 9
Acme). The terminal version (Ck) doesn't exist yet; build-and-run steps for it will
land here when it does.

## Tests

One nice consequence of keeping all the logic in a UI-less core: most of it can
be tested without spinning up an interface — which is exactly how we test it. The
suite uses Tcl's own `tcltest`:

    tclsh rio-core/tests/all.tcl

Tests live in `rio-core/tests/`, one `.test` file per area. If you add behaviour
to the core, add a case alongside it; a change to how editing works should show
up as a test that would have failed before.

The syntax highlighters are pure Tcl too, so they have their own headless suite —
no display needed:

    tclsh syntax/tests/all.tcl

The GUI has a headless smoke that drives the real frontend (open / edit through
the dumb-view proxy / save / undo) without ever showing a window — it needs a
display but stays off-screen:

    RIO_GUI_HEADLESS=1 wish rio-gui/tests/smoke.tcl

**A headless run must never ask you anything.** Under `RIO_GUI_HEADLESS` there is no
one at the display, so every blocking dialog (`tk_messageBox`, the file choosers) is
replaced by one that prints what it was about to ask and fails the run — a suite that
needs an answer has to supply it itself, the way `repos.tcl` and `reload.tcl` do. The
run's **exit code** is the verdict, not the `ALL CHECKS PASSED` line: a dialog reached
from a timer or event callback would otherwise let a suite finish and still have asked
a question nobody answered. If a test of yours deletes a fixture, use
`sandbox_drop_fixture` rather than `file delete -force` — it closes any tab still open
on that path first, which is what rio itself does, and what stops the next run stopping
on *"…has been deleted on disk. Keep it open in the editor?"*.

(On Windows that `VAR=x cmd` prefix is POSIX shell syntax PowerShell can't parse —
but no prefix is needed there, because the GUI test scripts set the variable
themselves: just `wish rio-gui\tests\smoke.tcl`. Windows contributors should read
[WINDOWS.md §8](WINDOWS.md), which also covers the two `git config` settings a
Windows clone needs and how to get an error message out of `wish`, which prints
none for an uncaught error.)

More focused GUI suites live beside it in `rio-gui/tests/` — for example
`repos.tcl` drives the whole extension-repository flow (scan, consent,
install, remove, the Extensions window) against fixture data, with no network
involved.

## Sending a change

- **Keep it focused.** One concern per change, small enough to review comfortably.
- **Keep the docs honest.** If your change shifts a design decision, note it in
  [AGENTS.md](AGENTS.md); if it changes what a *user* does or sees, update the
  matching topic in [docs/](docs/index.md) — the user manual — in the same commit,
  so the feature and its page never drift apart. The README stays the overview: a
  one-line entry there, the how-to in `docs/`.
- **A doc that restates the code needs a guard.** If your change makes a page repeat
  something the code decides — a list of keys, of paths, of commands — add a check to
  `rio-gui/tests/docs.tcl` and a row to AGENTS.md §7's *derived-facts register*. Every
  copy that nothing tests has drifted eventually; assert against what the code *does*,
  and check both directions, so an invented entry fails too.
- **Write menu paths in emphasis** — `***View ▸ Theme…***`, with ` ▸ ` between the
  levels. `docs.tcl` checks every such path against the real menubar, and the emphasis
  is what tells it where the label stops and your sentence starts. A path written
  bare is reported as if it were wrong, which is the nudge to mark it up.
- **Say why.** A short explanation of the reasoning — especially for anything
  touching the core's protocol — makes review much easier.

## License & code of conduct

*To be added before rio opens up to outside contributions.*

---

Want the deep design rationale — why rio is built the way it is, and the
trade-offs behind each decision? That's all in [AGENTS.md](AGENTS.md). Start
there.
