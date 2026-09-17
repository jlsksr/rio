# The rio manual

This is rio's user manual: how to use the editor, what each part of the window
does, and where your settings live. It is written for someone using rio, not
building it — no Tcl required.

The manual is a set of **topics**, one per file. Read it in order for a tour, or
jump to the topic you need.

## Contents

### Start here

- [Getting started](getting-started.md) — launching rio, the window explained,
  your first edit and save.
- [The editor](editor.md) — typing, selecting, undo, tabs, the split view,
  line wrap, syntax highlighting, columns.
- [Files & projects](files-and-projects.md) — the file tree, opening a folder,
  creating and renaming files, sessions.

### Doing the work

- [Find & replace](find-and-replace.md) — the find bar, the Search panel, and
  the scopes each one covers.
- [Git](git.md) — the git pane: status, diffs, staging, committing, discarding.
- [The agent](agent.md) — providers and keys, what the agent may do on its own,
  and what waits for your approval.

### Making it yours

- [Preferences](preferences.md) — every setting, what it does, and where rio
  keeps it on disk.
- [Keyboard shortcuts](keyboard.md) — the default chords and how to remap them.
- [Panels & layout](panels-and-layout.md) — moving panes, themes, fonts, zoom.
- [Editing modes](editing-modes.md) — Windows, vi, or emacs keys in the text area.
- [Extensions](extensions.md) — repositories, installing themes, highlighters,
  modes and agent providers.

### Beyond one machine

- [Working remotely](remote.md) — editing files on another box over an SSH tunnel.
- [Troubleshooting](troubleshooting.md) — what to check when rio misbehaves.

## Where else to look

The manual is one of several documents, each with its own job. It owns **how to
use rio**; the others own what they say on the tin, and the manual links to them
rather than repeating them:

| Document | Answers |
| -------- | ------- |
| [INSTALL.md](../INSTALL.md) | How do I install, deploy, and run rio? |
| [CAVEATS.md](../CAVEATS.md) | Known rough edges and platform differences |
| [README.md](../README.md) | What is rio, and what works today? |
| [WINDOWS.md](../WINDOWS.md) | Running rio on Windows 11 |
| [AGENTS.md](../AGENTS.md) | The design log — *why* rio works the way it does |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Hacking on rio itself |

## About these pages

The manual is plain Markdown, kept in the source tree alongside the code it
describes — so a feature and its page land together, and so rio can show these
pages itself, from disk, with no network. It does: ***Help ▸ Contents…***, or
`F1`, opens this contents page and every topic in it, formatted rather than as
source. Links are live in there — click one to jump to the topic (or the heading)
it names, and `Alt+←` / `Alt+→` walk back and forward through where you have
been. The **Find** box searches the whole manual: type a word and the contents
list becomes the sections that mention it, so picking one takes you straight to
that heading with the word highlighted. The page itself is read-only, but you can
select in it and right-click for *Copy* — a command in a code block is meant to be
lifted out. That intent shapes how they are written:

- **One topic per file, and the filename is the topic's name.** Filenames are
  stable: they are how a page is linked to, and how rio finds a topic to show you.
- **The first heading is the topic title**, matching its line in this contents
  page, and the first sentence says what the topic covers.
- **Links between topics are relative** — `[the editor](editor.md)` — so they
  keep working whether you read the files, browse them on the web, or open them
  inside rio.
- **A restrained slice of Markdown:** headings, paragraphs, lists, links, bold
  and italic, inline code, fenced code blocks, simple tables, and blockquotes for
  the occasional aside. No HTML, no images, no footnotes, no nested tables — only
  what a plain text window can render.
- **Plain voice.** What you do, and what rio does in return. Where a rule is
  easier to remember with its reason attached, the reason is one sentence, not a
  design essay; the essays live in [AGENTS.md](../AGENTS.md).

Some topics are still stubs. A stub says so, says what it will cover, and points
at the document that has the facts today — it never leaves you with nothing.
