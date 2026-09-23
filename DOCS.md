# Maintaining `docs/`

This document is for whoever maintains rio's user manual — the Markdown topics in
[docs/](docs/index.md). It is a handover: everything below is what the manual's rules
are and why, so you do not have to reconstruct them from the design log.

The manual is **content work**, and it is deliberately kept separate from rio's
development. If you are here to write documentation, you own `docs/`; if you are here
to change rio, you own the code, and your only obligation to the manual is the one in
[CONTRIBUTING.md](CONTRIBUTING.md): a change to what a user sees updates the matching
topic in the same commit.

---

## The one command

```sh
RIO_GUI_HEADLESS=1 wish rio-gui/tests/docs.tcl
```

It must print `ALL PASS`. It needs a `DISPLAY` (it sources `rio-gui.tcl` to reach the
real keymap and the real menubar) but shows no window and opens no files. On a headless
box, `xvfb-run` is enough.

**Run it before every commit.** It is fast, it has no network, and it is the only thing
standing between the manual and the kind of drift that takes three months to notice.

---

## What the suite actually holds you to

Eighteen groups of checks. Each exists because something drifted once.

1. **`docs/` and `index.md` agree.** Every page is listed in the contents, and every
   contents entry names a page that exists. A page nobody links to is invisible; an
   entry pointing at nothing is a dead end in the future help viewer.
2. **Every relative link resolves** — between topics, and out to the root documents
   via `../`. This one stops at the filename; the `#anchor` half is check 9.
3. **`keyboard.md` matches `::keymap_default`.** Every command in the keymap is
   documented, and the page invents none. The keymap is the single source of truth for
   chords; a shortcut table written by hand is how this started going wrong.
4. **`preferences.md` matches what `prefs_save` writes.** Every key the code persists
   is documented, and the page invents no key.
5. **"Where everything lives" matches the paths the code builds** — every file below
   the config and data directories, compared as a whole path, both directions. A row
   with `<name>` or `*` matches as a pattern. Comparing only the first folder let two
   files under `agent/` go undocumented behind a third.
6. **Every `Menu ▸ Item` path the docs quote is a real menu entry.** The check walks
   the live Tk menubar widgets, not the source text. Menus whose entries are *installed
   data* rather than facts of the code — the provider and editing-mode cascades, and
   the Extensions menu below its separator (D130) — are checked down to the menu and no
   further: what a reader sees there depends on what they have installed, and the form
   the manual has to teach (`Extensions ▸ <provider>…`) is a template, not a path.
6a. **The Extensions menu's first entry is named somewhere.** That one entry — the
   installer window — *is* a fact of the code, so exempting the menu would have left
   unguarded the very path D130 had just moved. Both halves come off the widgets: which
   cascade opens the menu, and what its first entry is labelled. Where it is documented
   is the writer's business, so the check asks only that some user-facing document says
   it.
7. **Every menu the docs *name* exists.** A capitalised word in front of *menu*,
   *submenu* or *cascade* is treated as a name and must be one rio has.
8. **The help viewer can reach the manual.** `help_dir` points at the real `docs/`, and
   the topics `help_contents` parses out of `index.md` are exactly the pages `index.md`
   lists — both directions, like check 1, one layer up. Two things break the viewer
   while every page stays perfect: the directory moves, or the contents list is
   rewritten into a shape the parser cannot read (a table, say) and the window opens
   empty.
9. **Every `#anchor` a page links to is a real heading.** Since the viewer scrolls to
   them (D100) an anchor is a destination, not decoration. It is checked against
   `help_slug` and `help_blocks` — rio's own slug rule, not a second copy of GitHub's —
   so it catches both an anchor that never named a heading and a heading whose wording
   was edited afterwards.
10. **`editor.md` lists exactly the editor's right-click menu.** The suite builds the
    real menu and holds the page against it both ways (D108).
11. **Every *Preferences ▸ Category ▸ Control* path the docs quote is real.** The suite
    opens the real Preferences window and matches each quoted path against its categories
    and its controls' labels. It is check 6 for the window, and it came from D114: the old
    Extensions path for Accepted certificates… stayed in two topics after the button moved
    to Network. Like check 6, it relies on the path being in emphasis.
12. **`getting-started.md` lists exactly the menus outside the editor.** Check 10's
    twin for D115: the read-only views' menu and the one every entry and text outside
    the editor carries. The suite runs both builders against fixtures of its own — a
    disabled text, a bare entry — so the check never depends on what a pane happens to
    hold, and reads the labels off the real menu widget. Both directions, on check 10's
    convention: in *Right-click menus*, bold marks an entry and nothing else.
13. **The pre-seeded repository URL the docs quote is the one rio seeds.** Derived from
    `::default_repo`, never spelled out: the host comes out of the constant, every
    inline-code URL on that host across the manual and the user-facing root documents is
    collected, and the set must be exactly the default. It exists because the URL moved
    from `/rio` to `/extensions` and a reader copying the stale one would add a
    repository that 404s while every page still read perfectly.
14. **The words a repository's signature makes rio say.** D118 put three user-visible
    vocabularies on screen — the one-word mark every version line ends in (`sig_mark`)
    and the phrase a refused source carries on its row (`dead_phrase`) — and
    `extensions.md` tabulates them. Behaviour, not source text: every phrase comes out
    of calling the proc, and the refusal *names* are enumerated from the live proc body,
    so a refusal added to rio with no row in the manual fails here rather than waiting
    to be noticed.
15. **Every door out of the Preferences window is named in the manual.** Check 11 in
    reverse, and the direction that was missing: check 11 holds the paths the docs quote
    against the real window, and nothing held the window against the docs — so a new
    button could land with every check green while the manual went on describing the old
    way of doing that job. That is exactly what D118's *Repository signing keys…* did.
    Buttons only, because a checkbutton is a setting and check 4 already covers those;
    the labels are read off the real widgets, and *where* the manual names one is the
    writer's business, so it matches the label in the prose rather than a full path.
16. **The words the two signing-key windows put on screen.** Check 15's blind spot:
    neither the confirm/rotation dialog nor the keys window is reachable from the
    Preferences window, so a renamed button in either could land with everything green.
    Both are really built — they block in `tkwait`, so each is driven from the event
    loop and closed — and the strings come off the live widgets: the dialog's two
    titles, its two trust buttons, and the `(built in)` / `(built in, withdrawn)` row
    annotations. It also asserts the dialog really has two forms and that opening it
    trusted nothing. From D119, where the dialog grew a second form and the keys window
    grew a second annotation, both of them words a user has to be able to look up.
17. **The facts *Help ▸ About rio* puts on screen.** `getting-started.md` tabulates the
    box's rows, so that table is a second home for a fact that lives in the dialog. The
    box is really built — it does not block, so unlike check 16 it needs no driving —
    the labels are read off the live widgets, and the table has to match them *in order*
    (D123 put `Version` first, which is also what retired the positional assertions in
    `smoke.tcl` — they look a row up by label now, so row order is held in one place
    instead of two). The licence the page quotes must be the one the box shows.
    `smoke.tcl` holds the dialog against the `LICENSE` file; this holds the manual
    against the dialog, so a relicensing that forgets one of the three fails in code or
    in prose.

    Since D123 it also holds the page's **version** claims, which are a fact of a
    different kind: one that changes at every release. The page is therefore held to
    quote **no version number at all** — a literal there would go stale on the next tag,
    and the box already states it. What the page *may* say is that rio is on `0.x` and
    what that means for the reader, and that sentence is held to `rio::version`: it must
    be present while the version starts `0.`, and gone once it does not. The expiry is
    real and singular — 1.0.0 is exactly the release most likely to ship with a
    paragraph still promising early days.

Checks 6 and 7 cover the same register row from two directions, because a menu can be
named two ways and only guarding the quotable one left the failure that prompted them:
a prose mention of a menu retired three decisions earlier sat in `WINDOWS.md` until a
human happened to read it.

### Conventions the guards depend on

- **Write menu paths in emphasis** — `***View ▸ Theme…***`, with ` ▸ ` (U+25B8, spaces
  either side) between levels. The emphasis is what tells check 6 where the label stops
  and your sentence starts; a path written bare runs into the prose and is reported as
  wrong. That report is the nudge to mark it up, not a bug.
- **A capitalised word before *menu* must name a real menu.** Describing one is free —
  "the row menu", "its pane's menu", "a right-click menu" are not names and are never
  looked at. Determiners and the compounds where *menu* is the adjective (`menu paths`,
  `menu bar`) are exempt by list.
- **Links between topics are relative** — `[the editor](editor.md)`.
- **In `editor.md`'s *The right-click menu* section, bold marks a menu entry** — and
  nothing else. That is what lets check 10 read the section as a list and catch an
  invented entry as well as a missing one. Emphasise anything else in there and the
  check will tell you.
- **Filenames are stable.** A filename is the topic's id: how pages link to it, and how
  the help viewer will one day jump to it. Renaming a page is a breaking change, not a
  tidy-up.

### The scope of checks 6 and 7

`docs/*.md` plus `README.md`, `INSTALL.md`, `WINDOWS.md`, `CONTRIBUTING.md`.

**`AGENTS.md`, `ROADMAP.md`, `CHANGELOG.md`, `CAVEATS.md` and this file are
exempt.** They name retired menus and unbuilt ones on purpose; holding them to today's
menubar would make them lie about their own history — a changelog entry describes the menu
as it was the day the change landed, which is the whole point of a dated entry. Do not "fix" a menu name in a design log — if it
describes what was true at the time, it is correct.

---

## Rules that no test can enforce

**Verify against behaviour, not against prose.** Before writing that rio does X, find
the code that does X and read it. A sentence copied from another document inherits its
errors — that is how the stale shortcut table survived as long as it did. Where a fact
lives in the core, `rio-core/` is the authority; where it lives in the GUI,
`rio-gui/rio-gui.tcl` is.

**Check both directions.** A page that misses a feature is a gap; a page that describes
a feature that no longer exists is worse, and it is the direction a reader never
notices, because invented facts read exactly like true ones.

**If a fact lives in both code and docs and has no guard, write the guard.** That is
the rule of the derived-facts register in [AGENTS.md](AGENTS.md) §7 and it applies
here: a row without a guard is a backlog item, and the fix is to write the guard, not
to schedule a re-read. Adding a check to `docs.tcl` is welcome and is the highest-value
thing you can do in this directory.

Three things to know before you write one. Checks are `ok "label" $got $want` and belong
in `docs.tcl` itself, which already sources `sandbox.tcl` — mandatory for any GUI test,
because rio persists to the real XDG directories and an unsandboxed run clobbers the
owner's config. **Assert against behaviour**: source what builds the fact and inspect the
result, never `grep` the source text, or the check passes on a comment. And **prove the
check fails**: inject the drift it is meant to catch, watch it fail by name, then revert.
A guard that has only ever been seen passing is not yet a guard — the menu check passed
its first injected rename, which is why it now matches labels exactly.

rio is **Tcl/Tk only**. No Python, not even for a scratch script; use `tclsh` and a
temporary `.tcl` file.

**A stub says so.** Several topics are still placeholders by design. A stub states that
it is one, says what it will cover, and points at the document that has the facts
today — it never leaves the reader with nothing. Currently stubs:
`files-and-projects.md`, `find-and-replace.md`, `panels-and-layout.md`,
`editing-modes.md`, `remote.md`, `troubleshooting.md`, and `extensions.md` apart from its
sections on signatures and on certificates that aren't trusted — both of which are
complete, and the page says so itself.

**Keep the Markdown restrained.** Headings, paragraphs, lists, links, bold, italic,
inline code, fenced code, simple tables, blockquotes. No HTML, no images, no footnotes,
no nested tables. rio will render these pages itself one day, from disk, in a plain
text window — so anything fancier is a promise the viewer cannot keep. If you believe a
page needs a construct outside this list, raise it rather than adopting it: it is a
change to the viewer's requirements, not a formatting preference.

**Plain voice.** What the reader does, and what rio does in return. Where a rule is
easier to remember with its reason attached, give the reason in one sentence. The
essays belong in `AGENTS.md`.

---

## Where a fact belongs

The manual owns **how to use rio**. It links to the others rather than repeating them,
and a fact in the wrong document is drift waiting to happen.

| Document | Owns |
| -------- | ---- |
| `docs/` | How to use rio |
| `README.md` | What rio is, and what works today |
| `INSTALL.md` | Installing, deploying, running — every deployment detail |
| `WINDOWS.md` | Running on Windows 11 |
| `CAVEATS.md` | Known rough edges; anything that works on one OS or WM but not another |
| `AGENTS.md` | The design log — *why* rio is the way it is. Numbered decisions |
| `CONTRIBUTING.md` | Hacking on rio itself |
| `ROADMAP.md` | Candidate next steps |
| `CHANGELOG.md` | The user-visible history, newest first |

**`CHANGELOG.md` is not the manual's, but the same rule applies**: it is
[Keep a Changelog](https://keepachangelog.com/) form, one section per release, and every
entry cites its decision, a commit and a date. A change to what a user sees adds its entry
there in the same commit — `changelog.test` is what tells you when it did not.

**Do not edit code to make a doc pass.** If a check fails, either the doc is wrong or
you have found a real defect in rio. Both are worth reporting; only the first is yours
to fix here.

---

## Things a documentation writer gets wrong about rio

Landmines, each of which has already cost someone a rewrite.

- **rio does not dial out.** The GUI reaches a core with `--connect host:port`, and
  that is the whole story. There is no `--ssh` flag, no tunnel helper, no connection
  manager, and none is planned — if a user wants a tunnel, they build it themselves
  with the tools they already have. Never document, propose, or imply otherwise.
- **"Remote" means *where the core runs*.** Over a remote core, the files, the git
  repository and the commands are that machine's. The GUI never touches them directly;
  it asks the core, exactly as it does locally. Every pane behaves identically — that
  is the point, and it is worth stating on pages that describe a pane.
- **Editing modes are extensions.** The core ships only the windows mode in `modes/`;
  vi and emacs are installable extensions in `extensions/` and ride the same contract.
  Documents that point at `modes/vi.tcl` are pointing at a file that does not exist.
- **The git pane writes.** It stages, unstages, commits and discards — it is not a read
  pane. It does not do branches, history, remotes or merges, and that is a stated
  choice rather than a gap.
- **The file tree keeps itself current** when rio itself writes to disk (an agent edit,
  a discard, a project-wide replace), when rio regains focus, and on a manual refresh.
  It is not a live filesystem watcher.
- **Menus move.** Grouping items into submenus is an active design strategy, so a path
  correct last month may be wrong today. This is exactly why checks 6 and 7 exist —
  trust the suite over any path you find written down, including one in this file.

---

## Committing

Commit your work; **do not push** — the project owner pushes. Keep manual changes in
their own commits, separate from code. Say in the message what drifted and how you
verified the replacement, not merely that you updated a page.
