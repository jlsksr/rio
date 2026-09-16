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

Ten groups of checks. Each exists because something drifted once.

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
   the live Tk menubar widgets, not the source text.
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

**`AGENTS.md`, `ROADMAP.md`, `PITCH.md`, `CAVEATS.md` and this file are exempt.** They
name retired menus and unbuilt ones on purpose; holding them to today's menubar would
make them lie about their own history. Do not "fix" a menu name in a design log — if it
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
section on certificates that aren't trusted.

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
| `PITCH.md` | The pitch and the human changelog |

**Do not edit `PITCH.md`.** It is only ever touched on an explicit request from the
project owner, and never with a proactive changelog entry.

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
