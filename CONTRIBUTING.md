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

### The application icon

`rio-gui/icons/` holds the window and taskbar icon: the candidate artworks under
`sources/`, the sizes cut from the active one, and `active` naming which that is.
All committed.

```sh
./rio-gui/icons/make-icons.sh --list            # what's available, and which is on
./rio-gui/icons/make-icons.sh redeemer-yellow   # switch to another candidate
./rio-gui/icons/make-icons.sh ~/my-icon.png     # adopt a new one (kept in sources/)
```

Any square PNG, 512×512 or larger, with a transparent background. The script
re-cuts every size and the Windows `.ico`. Nothing is overwritten — old artwork
stays in `sources/`, so going back is the same command with the other name. It
needs ImageMagick, which **only contributors doing this** need: rio never runs the
script, and reads the finished PNGs with Tk's own PNG support.

**If the artwork isn't yours, record its credit** in
`rio-gui/icons/sources/ATTRIBUTION.md`, in the same commit that adds the file.
rio's current icons are Flaticon's, whose free licence requires attribution — so
this is a condition of use, not a courtesy, and it applies to every artwork in
`sources/` whether or not it is the one currently worn.

Look at the **16×16** before you commit — it is what the title bar and the taskbar
actually show, and detail that looks good at 256 turns to mush there. The thing
that decides whether an icon works at that size is **contrast at its outer edge**,
against *both* light and dark window chrome; rio's first icon was replaced for
failing exactly that on light title bars.

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
- **The agent's instructions ship with rio — keep them in step with its tools.**
  `agent/prompt.md` (and `agent/plan.md` for plan mode) is what every provider is
  told, composed in the core so one file shapes Claude, an OpenAI-compatible model
  and a local one alike. Give the agent a new tool, a new gate or a new mode, and
  that file is part of the change; it is plain Markdown, and users can read it —
  and replace it — from *Preferences ▸ Agent ▸ Agent Prompts…*, so write it for
  them too.
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
    version = 1.0.0
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
`description` and `maintainer` are optional and shown alongside. `key` is optional
and publishes the signing key rio checks your `SHA256SUMS` against — *Signing your
repository*, below.

`rio-extension.conf`, per extension directory:

| key           | required | meaning                                                        |
| ------------- | -------- | -------------------------------------------------------------- |
| `name`        | yes      | the extension's name — users see it as *kind/name*             |
| `kind`        | yes      | what it is: `syntax`, `mode`, `theme`, or `provider` today (open — below) |
| `version`     | yes      | **[semver](https://semver.org/)** — `MAJOR.MINOR.PATCH`, optionally `-prerelease` (`1.2.0`, `2.0.0-rc.1`). rio compares it to decide what is an update |
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
- **`http://` or `https://` — your choice, and your users'.** Plain http is
  fully supported and always will be; https is an option, not an obligation,
  the way it is for a Debian mirror. Serve either or both. An https repository
  needs **tcltls 1.8 or newer** on the user's core (the first version that checks
  a certificate's name against the host), and it is verified against **that
  host's own CA store** — so a certificate from a public CA just works, and a
  private CA works once the user trusts it there (or points `SSL_CERT_FILE` at
  it). If your https host redirects to plain http, rio refuses the redirect;
  http → https is followed. The trust section below is honest about what https
  does and doesn't buy.
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
  (`provider-api = 3` today). The core loads the API surface — `rio::agent::register_provider`
  (with `-label`, `-signup`, a `-key` capability, and since **2** an `-options`
  capability), the provider proc contract
  `{conversation tools system post}` with its `delta` / `tool` / `done` / `error`
  callbacks, and the runtime helpers `rio::llm::http::stream` (and `::get`),
  `rio::llm::jstr` / `rio::llm::obj_json` (and since **3** `rio::llm::jascii`),
  `rio::secret::*` and `rio::agent::settings::*` — *before* your code,
  so you ship no copy of it. A rio that implements an older `provider-api` than you
  declare lists your provider greyed ("needs a newer rio") and won't install it;
  declaring `1` still works on a newer core, since the surface only grows. That
  greying is the point: it is what stops a provider calling a helper the core it
  landed on does not have.
- **Hand the HTTP layer a pure-ASCII body.** `jstr` guarantees that for every value
  it escapes, but anything you splice in *already serialised* — a tool's
  `input_schema`, a tool_use block's captured input — has never been through it. End
  your body with **`rio::llm::jascii`**: it `\u`-escapes every non-ASCII character of
  an already-valid JSON document, which is safe because JSON can only carry one
  inside a string literal. This is not theoretical: Tcl's `http` counts
  `Content-Length` in *characters* and then writes the body to a *binary* channel, so
  a stray `—` leaves as the byte `0x14` — a raw control character inside a string,
  which RFC 8259 forbids. One vendor rejected the request outright; another had been
  silently accepting it.
- **Options are how a provider offers choices** (a model, an effort, anything else
  it names). `-options {list <cmd> set <cmd> ?refresh <cmd>?}`: `list` returns
  descriptors `{name label hint value free refresh choices {{value .. label ..} ..}}`,
  `set` validates and applies one, `refresh` re-enumerates asynchronously and calls
  the announce callback it is handed (with a message, if it failed). The core routes
  by name and never learns what an option means, so a frontend renders whatever you
  declare — no GUI change for your third knob. Persist a choice with
  `rio::agent::settings::store <you> <key> <value>` and read it back at registration:
  it lands in one flat, hand-editable file per provider.
  ([extensions/openai/](extensions/openai/) is a complete worked example — the
  OpenAI-compatible provider ships exactly this way.)
- **The user is warned, specifically.** Because your code runs in the core (which
  may be a shared or remote host), can be handed the API key the user enters for it,
  and makes network calls with it, the install dialog says so and names your source.
  Publish from a source people can trust with their model credentials.

### Signing your repository (optional, and worth it)

rio treats plain `http://` as first-class, which means anyone between your server
and a user can rewrite a payload in flight. A signature is what makes that fail —
without a certificate, a registry, or an account anywhere. It is two commands at
publish time and needs no rio tooling.

**Once**, make a key and publish its public half in `rio-repository.conf`:

    ssh-keygen -t ed25519 -f ~/.ssh/my-rio-repo -C 'my rio repository'
    cut -d' ' -f1,2 ~/.ssh/my-rio-repo.pub        # type and base64, no comment

    key = ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA…    ← into rio-repository.conf

**Every publish**, from the repository root — note that adding the `key =` line
changed a hashed file, so do it in that order:

    find . -path ./.git -prune -o -type f \
        ! -name 'SHA256SUMS' ! -name 'SHA256SUMS.sig' -print \
        | sed 's|^\./||' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
    ssh-keygen -Y sign -f ~/.ssh/my-rio-repo -n rio-repository SHA256SUMS

`SHA256SUMS` is `sha256sum`'s own format (OpenBSD's `sha256 -r` prints the same),
covering **every file you serve**; `SHA256SUMS.sig` signs that one file, so it
covers the repository transitively. There is no per-extension signature — you sign
the repository, not `vi/`. `-n rio-repository` is the namespace, and it is what
stops a signature you made for git being replayed as a repository signature. Keep
the private key off the web server; a passphrase plus `ssh-add` keeps signing
non-interactive.

**Publish your fingerprint where a user can check it** — your project page, a
release note, the mail you announce the repository in:

    ssh-keygen -lf ~/.ssh/my-rio-repo.pub          # SHA256:…

rio asks each of your users to confirm it once, and the only way they can answer is
by comparing it against something of yours that is not the repository itself. Signing
without publishing the fingerprint leaves them clicking yes on faith.

What rio does with it (AGENTS.md D118, D119), so you can predict what your users see:

- The **first** scan that verifies your signature does **not** record your key — it
  refuses your repository and shows the user your fingerprint, the way `ssh` does on
  a first connection. Once they confirm it, only that key speaks for your repository,
  and rio checks every file it fetches from you — marker, `index`, manifests,
  payloads — against `SHA256SUMS`, at scan time and again before an install writes
  anything. So a new user's very first sight of your repository is a question about
  you; make the fingerprint easy to find.
- **A file that isn't in `SHA256SUMS` is refused**, as firmly as one whose hash
  differs: your sums cover everything served, so an unlisted file did not come from
  you. This is the failure mode to know about — **re-sign on every publish**, and
  upload payloads first, `SHA256SUMS` and `SHA256SUMS.sig` last (or stage and swap).
  A client scanning mid-upload otherwise sees old sums against new payloads and
  refuses the whole repository until you finish.
- **Rotating your key** is a deliberate act: every rio that trusted the old one
  refuses the new one as *changed* until the user reviews the fingerprints and
  accepts — or forgets the old key under *Preferences ▸ Extensions ▸ Repository
  signing keys…*, which puts your repository back to being asked about. There is no
  cross-signing and no revocation — expect to announce it, with the new fingerprint.
- **Dropping signing again** is refused the same way, so don't start if you can't
  keep it up. An unsigned repository stays perfectly valid; it is simply marked
  *unsigned* for the user, which is what it is.

Your dry run is the same check a user's rio will do, and it is worth running before
every upload:

    sha256sum -c SHA256SUMS --quiet && echo 'payloads ok'
    printf '%s %s\n' http://yourserver.example/rio \
        "$(cut -d' ' -f1,2 ~/.ssh/my-rio-repo.pub)" > /tmp/allowed-signers
    ssh-keygen -Y verify -f /tmp/allowed-signers -I http://yourserver.example/rio \
        -n rio-repository -s SHA256SUMS.sig < SHA256SUMS

The two catch different things, and you want both: a payload changed after hashing
passes the signature check and fails `sha256sum -c`; an edited `SHA256SUMS`, the
wrong key, or the wrong namespace does the opposite. (rio derives the identity from
the source URL itself, so you never ship an allowed-signers file.)

**Verifying needs OpenSSH 8.0+ on the user's core host** — everything current has
it; Windows 10 1809's bundled 7.7 does not. A user without it is told what to
install rather than served your repository unchecked.

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

If you sign, check the **served** bytes rather than your working tree — a partial
upload passes locally every time. Mirror the published tree into an empty directory
(`wget -r`, or curl every path `SHA256SUMS` names) and run the two checks from
*Signing your repository* there.

### Versions are semver

`version` is a **[semver](https://semver.org/)** string — `MAJOR.MINOR.PATCH`,
with an optional `-prerelease` (`1.2.0`, `2.0.0-rc.1`, `0.9.0-beta.2`). That is
the one thing rio asks you to follow rather than merely display, because it is
what lets a user's editor tell them your new release *is* newer.

The comparison is ordinary semver: numeric fields compared as numbers (so
`1.10.0` beats `1.9.0`), a pre-release ranking below the release it leads to,
and `+build` metadata ignored. rio is lenient about one thing only — a
two-component `1.1` is read as `1.1.0`, because versions predating this rule are
still installed out there. Anything it can't read as a version (a bare date, a
`v2-final`) is **shown but never compared**: your extension lists and installs
normally, it just never tells anyone an update is waiting. That is the cost of
not following the rule, and it is the whole cost.

### Updating & removing

To ship a new version, update the payload files and **bump `version =`**. Users
see it as `[1.1.0 → 1.2.0]` on the row, update one extension with a button or
all of them at once, and can have rio look for new versions when it starts.
**rio never auto-updates** — it only ever tells.

An update is offered from **the repository the user installed from**, not from
whichever source happens to list the highest number. Nobody owns a name here,
so a same-named extension in another repository is a different thing the user
may deliberately switch to, never a silent upgrade path into your users.

To retire an extension, delete its directory (and its `index` line): it unlists,
while existing installs keep working and stay removable — each user's rio
remembers what it installed, and from where.

### Trust, honestly

- Installing a **syntax highlighter or an editing mode is installing Tcl code
  that runs inside the user's editor**, with the user's permissions. rio says
  exactly that at install time, next to your source URL. There is no sandbox:
  **your URL is your reputation**, and a user's sources list is their trust list —
  exactly like apt's.
- **What a signature adds, and what it doesn't.** It says these bytes came from
  the holder of your key and were not altered in transit — over plain http, which
  is the point. It says nothing about the code being good, reviewed or approved by
  anyone. There is no store here and no authority; signing is integrity, not
  endorsement.
- **What https adds, and what it doesn't.** It proves the files came from the
  host in the URL and weren't altered on the way. It says nothing about who
  wrote them or whether the host itself is trustworthy — that is still your URL
  and your reputation. The same repository over http and over https is the
  same repository to rio: a user who switches schemes keeps their updates, and
  their trust in your signing key.
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

**Read the skip count, not just the failures.** `tls.test` mints certificates with the
`openssl` CLI and serves them over loopback; without that binary on the `PATH` its whole
half — 19 tests, the D109–D111 https work — skips, and tcltest says so only as a tally
at the very end. A run that prints `0 failed` can still have tested none of it. A normal
developer box has `openssl`; a minimal container often doesn't, and neither does Windows
by default (WINDOWS.md §8). Apart from those, only three tests should skip, under the
`unix` constraint.

Non-ASCII **values** in a `.test` — data or expected results — are written as `\u`
escapes, never as literals. tcltest runs each file in a child `tclsh` that decodes it
with the system encoding, so a literal is mojibake anywhere that isn't UTF-8 and no
setting in the runner can prevent it. Comments and test descriptions are unaffected.

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
  one-line entry there, the how-to in `docs/`. The manual has rules of its own —
  what each page owes the reader, what the test suite enforces, and the facts about
  rio that documentation routinely gets wrong — collected in [DOCS.md](DOCS.md).
- **A doc that restates the code needs a guard.** If your change makes a page repeat
  something the code decides — a list of keys, of paths, of commands — add a check to
  `rio-gui/tests/docs.tcl` and a row to AGENTS.md §7's *derived-facts register*. Every
  copy that nothing tests has drifted eventually; assert against what the code *does*,
  and check both directions, so an invented entry fails too.
- **Write menu paths in emphasis** — `***View ▸ Theme…***`, with ` ▸ ` between the
  levels. `docs.tcl` checks every such path against the real menubar, and the emphasis
  is what tells it where the label stops and your sentence starts. A path written
  bare is reported as if it were wrong, which is the nudge to mark it up. Naming a
  menu in a sentence is checked the same way — a prose mention of a menu retired two
  releases earlier is how the last stale one got past everybody — so a capitalised
  word in front of *menu*, *submenu* or *cascade* has to name one that exists.
  Describing one is still free: "the row menu" is not a name.
- **Say why.** A short explanation of the reasoning — especially for anything
  touching the core's protocol — makes review much easier.

## License & code of conduct

*To be added before rio opens up to outside contributions.*

---

Want the deep design rationale — why rio is built the way it is, and the
trade-offs behind each decision? That's all in [AGENTS.md](AGENTS.md). Start
there.
