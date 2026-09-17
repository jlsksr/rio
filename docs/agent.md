# The agent

rio's chat column, where an AI model works on your project — reading files,
proposing edits, and running commands, with you approving anything that changes
something.

`Ctrl+Shift+A` shows and hides the pane, or ***View ▸ Agent***.

## The rule that shapes everything else

**Reading is free. Writing waits for you. Commands always wait for you.**

The agent can look around your project as much as it likes — list folders, read
files, read the buffers you have open, including your unsaved edits — and it shows
you each thing as it does it. But it cannot change a file or run a program without
an explicit approval from you in the chat pane.

That asymmetry is the whole design. Reading is recoverable; writing and running
are not, so those get a gate.

## Choosing a provider

Out of the box rio ships one provider: **echo**, an offline stub that needs no key
and no network. It exists so the chat pane works and can be tested — it is not a
model.

Real providers install as **extensions** from ***Settings ▸ Extensions…***:

- **Claude**, over the official Anthropic API.
- **ChatGPT**, over the OpenAI API. Because it speaks the OpenAI-compatible
  protocol, pointing its base URL at a **local** server — Ollama, llama-server, LM
  Studio, vLLM — runs a local model through exactly the same path, usually with no
  key at all.

Pick the live one in ***Settings ▸ Agent Provider*** (a quick switch you make
mid-session) or in ***Preferences ▸ Agent***, which is also where each provider's
heavier configuration lives. See [extensions](extensions.md) for adding a
repository to install from.

## Choosing a model, and how hard it thinks

The strip along the **bottom of the agent pane** names the agent you are talking to
— **`Claude · Sonnet 5 ▾`** — and clicking it is how you change that. It is one menu
with a section for each choice:

- **Provider** — the same picker as ***Settings ▸ Agent Provider***, next to the
  rest of the decision rather than two menus away.
- **Model** — the models that provider offers. The list is short and shipped, so it
  goes stale: **Other…** takes any model id you type (a release newer than your rio,
  a tag on your own server), and **⟳ Refresh from provider** replaces the list with
  what your key — or your local server — can actually reach right now.
- **Effort** — how much thinking to ask for. **Provider default** sends nothing at
  all, which is what rio has always done; the other values are opt-in, because not
  every model accepts the request (`gpt-4o` and most local servers refuse it, and so
  does Claude Haiku). For Claude, a refresh also learns *which* models take an effort
  and which values they take — so after one refresh the menu offers only what the
  model you picked will actually accept, and switching to a model that takes none
  sends none rather than losing the turn to an error.

Whatever is *not* at its default is spelled out in the strip, so a raised effort is
never something you have silently left on. Hover for the full state, raw model id
included.

Each provider remembers its own choices, in a plain file you can read or edit
yourself:

```
$XDG_CONFIG_HOME/rio/agent/providers/claude.conf
```

```
model = claude-opus-5
effort = high
```

It sits beside that provider's prompt layer and its allow-list, and it lives **on
the core's machine** — with a remote core, the menu shows the models that core can
reach, and the file is on the server.

## Your API key

***Preferences ▸ Agent ▸ `<provider>` API Key…*** stores the key for a provider.

The key is never written into `prefs.json` or any other settings file. It lives on
its own, mode `0600`, in rio's data directory — see
[preferences](preferences.md#where-everything-lives) for the exact path. A local
OpenAI-compatible server usually needs no key; providers that do are marked
*(API key)* in the picker, and the offline ones *(offline)*.

**The agent runs in the core, not in the window.** With a remote core, the turn is
made on the server and the key is stored there — which is a real consideration if
that machine isn't yours. rio says so plainly when you connect. See
[working remotely](remote.md).

## HTTPS on an older tcltls

A hosted provider is reached over https, from the **core**, with the core's
`tcltls`. A `tcltls` older than 1.8 checks that a certificate was issued by a
trusted authority but never that it was issued *for the provider* — any valid
certificate for any host would pass. So on such a core the agent **refuses https**
before it connects, and the error names both ways out:

- install `tcltls` 1.8 or newer on the core's host and restart the core (see
  [INSTALL.md](../INSTALL.md)); or
- if that host can't be upgraded, tick *Preferences ▸ Network ▸ "Allow https without
  host-name checks (tcltls older than 1.8)"*.

The box is **off** by default. It changes nothing on a `tcltls` that checks names,
and plain `http://` — a local Ollama or llama-server — is never affected.

It is one switch for the whole core, not the agent's alone: https extension
repositories obey the same box. It is stored on the core's host, in `tls.conf`, and
every window attached to that core sees the same answer —
[preferences](preferences.md#network-how-the-core-checks-https) has the details.

A certificate you [accepted for a repository](extensions.md#a-certificate-that-isnt-trusted)
counts for the agent too, on that same host and port; the agent has no review of its
own.

## A turn, step by step

You type a request and press **▶** (or `Enter`). The agent streams its reply into
the pane, and along the way it may do three kinds of thing:

1. **Read** — "listing `src/`", "reading `parser.tcl`". These happen immediately
   and are shown as they go.
2. **Propose an edit** — a change to a file, or a new file. You get a **diff** and
   two buttons: **Approve** or **Reject**. On approval rio applies the change and,
   by default, saves it. A *complex* edit opens in the full side-by-side
   [compare view](editor.md#comparing-two-documents) rather than inline; the
   ***Compare complex edits*** toggle in *Preferences ▸ Agent* turns that off if
   you prefer everything inline.
3. **Propose a command** — a test run, a linter, a build. You see the **exact
   command** before anything happens, and approve or reject it. Approved commands
   run confined to your project and are time-boxed, so a runaway process cannot sit
   there forever.

A turn runs until the agent is finished — there is no step limit, because a job
worth doing takes the steps it takes. While it works, the **▶** button becomes
**■ Stop**: press it and the turn ends where it stands. Nothing half-applied is
left behind, since every change had to pass the gate first; the request already
sent to the provider is still paid for, so stop it because you changed your mind,
not to save a fraction of a cent.

## Changing just the selection

Select some text in the editor, right-click it and choose **Change with Agent…**.
A small window names what you selected — *Selection: parser.tcl, lines 12–20*
(a selection that ends at the very start of a line doesn't count that line) — and
takes your instruction: "rename `tok` to `token`", "make this loop iterative".
`Enter` sends it, `Shift+Enter` starts a new line, and **Cancel** or `Esc` drops it.

Sending brings the agent pane into view, because the review happens there. Your
request shows as an ordinary **You** message, with a muted line underneath saying
which selection it is about.

**The agent can change the selected text and nothing else.** As with plan mode,
this is a restriction, not a request: for that one turn the agent is handed a single
changing tool, which replaces exactly the selected text. It has no way to edit
another part of the file, touch another file, create one or run a command. It can
still read your project, for context. In plan mode it can only read and present a
plan, as always.

The change goes through the same gate as any edit — a diff with **Approve** and
**Reject**, the compare view for a complex one, and no question at all when you have
chosen auto-accept. The editor stays live while you decide:

- if you changed the **selected text itself** in the meantime, the edit is refused
  and nothing is replaced — select it again and ask again;
- if you only edited above it, so the text merely moved, the edit still lands on it
  (as long as that text appears only once in the buffer).

One `Ctrl+Z` takes the whole replacement back. A buffer with a file is saved the way
any approved agent edit is; an untitled buffer works too, and is never saved.

The restriction lasts for that turn only: the next message you type in the chat is
an ordinary request again.

**Where the entry appears.** Only while a provider other than Echo is selected, and
only while *Preferences ▸ Agent ▸ "Show “Change with Agent…” in the editor's context
menu"* is ticked, which it is by default. Untick it and the editor's right-click menu
is plain editing again. The entry is greyed when nothing is selected, and while a
turn is still working or waiting for your approval.

## Planning before building

For anything bigger than a small fix, you can ask to see the plan first.

**Just ask.** "Plan this first", "what would you do?", "show me the plan before you
touch anything" — the agent can present a plan in any mode, and will offer one
unprompted before a large or hard-to-reverse change. You do not have to remember to
flip a switch to get one.

**Plan mode** is the stronger version, for when you want a guarantee rather than a
habit. Set the agent's mode to **Plan** — the menu at the top of the chat pane, also
***Settings ▸ Agent Mode*** and *Preferences ▸ Agent* — and describe the job as usual.

While plan mode is on the agent **cannot change anything** — not as a promise it
makes, but because it is handed no editing and no command tools at all. It can only
read your project and then do one thing: present a plan. That is the difference
between the two: asking for a plan is a request, plan mode is a restriction.

The plan opens **in the middle of the window**, where the editor sits, formatted
the way the manual is — headings, lists, tables — because it is meant to be read
rather than skimmed. The chat pane keeps the decision:

- **Approve ▾** starts the work, and asks how you want it to go — *review each
  edit*, or *auto-accept edits* from here on. You choose once you have read the
  plan, rather than setting a switch beforehand.
- **Edit plan** opens the plan as an ordinary file, so you can change it before you
  approve it. Rewrite a step, delete one, add a constraint; then approve. The agent
  is given **your** version, edited or not — you do not have to save it first.
- **Reject** starts nothing, and leaves plan mode on if that is where you were. Say
  what you want different and let it try again.
- **Plan** reopens the plan if you closed it; `Esc` or **× Close plan** puts the
  editor back while you think.

Every plan is also saved in your project, under `.rio/plans/`, with the date and
its title in the filename — including the ones you reject. They are plain Markdown:
keep them, read them later, or delete the folder; nothing in rio depends on them.
(Add `.rio/plans/` to your `.gitignore` if you would rather they didn't travel with
the code.) That file is not a copy — it *is* the plan, which is why **Edit plan**
simply opens it.

Plan mode is part of rio, not of one model's API, so it works the same whichever
provider you have installed.

## Loosening the gate, deliberately

Two escape hatches exist, and they are separate on purpose.

**Auto-accept edits** is the agent's third mode, beside *Plan* and *Review*: it
applies proposed **edits** without asking. Useful when you are watching a long
refactor and reviewing in git afterwards. It never covers commands. Set it from the
menu at the top of the chat pane, from ***Settings ▸ Agent Mode***, or in
*Preferences ▸ Agent* — and, when you have just read a plan, from the plan's own
**Approve ▾** button.

The three modes are exclusive, and the menu always shows which one is live, so the
agent can never be quietly auto-accepting while the pane says it is planning.

**Allowed commands** is standing approval for **specific commands**, which you
author yourself. When the agent proposes a command, the approval bar carries an
**Always allow ▾** button offering two rules:

- **the program** — a one-word rule like `pytest` trusts every run of that program;
- **that exact command** — `git status` trusts only commands that *start* that way.

Each rule goes into one of three lists, and you pick which:

| Scope | Applies |
| ----- | ------- |
| All projects | everywhere, for every provider |
| This project | only in the folder you have open (stored in the project's `.rio/`) |
| A chosen provider | only while that provider is the live one |

A command runs unasked if **any** active list allows it. Review, add and remove
rules in ***Preferences ▸ Agent ▸ Allowed commands…***; all three lists are plain
text files you can also edit by hand, listed in
[preferences](preferences.md#where-everything-lives). Removing a rule makes that
command ask again.

## Telling the agent how you work

***Preferences ▸ Agent ▸ Agent Prompts…*** lists **everything the agent is told**,
in the order it is composed. Five layers, all plain Markdown, all optional except
the first:

| Layer | Applies to | Lives | Yours? |
| ----- | ---------- | ----- | ------ |
| rio's instructions | every turn | ships with rio | read it; replace it if you want |
| System | every project, every provider | with your rio settings | yes |
| Per-provider | only while one chosen provider is running | with your rio settings | yes |
| Project | the folder you have open | `.rio/agent.md` in the project | yes |
| Plan mode | only while the agent is in Plan mode | ships with rio | read it; replace it if you want |

Your three open in rio's own editor and are **added on top of** rio's — they never
replace them, so an empty prompt is a perfectly normal state and a badly worded one
cannot break the agent's tool contract.

The split is about reach. General standing instructions ("prefer small commits",
"this codebase is POSIX shell") belong in the **system** prompt, where they shape
whichever model runs. Facts about one codebase belong in the **project** prompt,
which travels with the code in git. Quirks of one model belong in the
**per-provider** prompt, so switching models doesn't drag them along.

Beside each layer the list says what it is doing right now — *in effect now*,
*empty*, *not created yet*, *not in effect now* — so you can see at a glance which
of your instructions are actually reaching the model.

### Reading rio's own instructions

The first and last layers are rio's, and they are **not hidden from you**. They are
what makes the agent behave the same whichever provider you install: the tool
contract (reads are free, writes are proposed), how to work in someone else's
codebase, how to run commands, what to verify before saying it works — and, in Plan
mode, how to investigate and what a plan should contain.

- **View rio's instructions…** opens the shipped text, rendered, read-only. The line
  above it names the file, so you can also open it in any editor you like.
- **Show the whole prompt…** renders every active layer joined together — the exact
  string the provider is sent, with nothing summarised or paraphrased.
- **Make my own copy…** writes that text to your own settings as an editable file
  and opens it. From then on your copy *replaces* rio's for that layer, and rio's
  later improvements no longer reach it — delete the file to go back.

Because the agent runs in the core, these are the files on the **core's** machine.
With a [remote core](remote.md) the dialog shows that machine's paths, which are the
ones that matter.

## What the agent cannot do

- Run anything outside the open project, or without your say-so unless you trusted
  it yourself.
- Act while you're away: there is no cron, no background loop, no unattended mode.
  A turn happens because you asked for one.
- Reach your API key from a settings file — it isn't there.

## Further reading

- [Extensions](extensions.md) — installing Claude, ChatGPT, or another provider.
- [Preferences](preferences.md) — where the key, prompts and allow-lists live.
- [Working remotely](remote.md) — what changes when the core is on another box.
