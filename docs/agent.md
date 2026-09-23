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

Real providers install as **extensions** from ***Extensions ▸ Browse…***:

- **Claude**, over the official Anthropic API.
- **OpenAI-compatible**, which drives hosted ChatGPT *or* any server that speaks the
  same protocol — Ollama, llama.cpp / llama-server, llama-swap, vLLM, LM Studio.
  Which of those it talks to is a **setting**, not a different extension; see
  [running a model of your own](#running-a-model-of-your-own).

A provider runs inside the core, and the core loads the ones it has only when it
starts — so **restart rio** after installing one. Until you do, that extension's row
in the Extensions window says so instead of offering its settings.

Pick the live one in ***Settings ▸ Agent Provider*** (a quick switch you make
mid-session) or in ***Preferences ▸ Agent***. Everything that belongs to the
provider *itself* — its key, its server, its model — is set in
[its own window](#a-providers-own-settings) instead, under the **Extensions** menu.
See [extensions](extensions.md) for adding a repository to install from.

## Choosing a model, and how hard it thinks

The strip along the **bottom of the agent pane** names the agent you are talking to
— **`Claude · Sonnet 5 ▾`** — and clicking it is how you change that. It holds the
handful of choices worth changing between turns; everything else a provider lets you
configure is in [its settings window](#a-providers-own-settings). It is a single
menu, with a section for each choice:

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

Everything the provider *declares* in the settings window below lands in that same
file, so which keys it holds depends on the provider — the one thing that never does
is the API key, which lives apart from every settings file. It sits beside that
provider's prompt layer and its allow-list, and it lives **on the core's machine** —
with a remote core, the menu shows the models that core can reach, and the file is on
the server.

## A provider's own settings

Everything that belongs to a provider — its key, and the rest of what it lets you
set — is configured in a window of its own, opened from the **Extensions** menu:

***Extensions ▸ `<provider>`…***

That menu carries one entry per installed extension that has anything to configure,
named after the extension — so with Claude and the OpenAI-compatible provider
installed you get ***Claude…*** and ***OpenAI-compatible…***. A provider's row in the
Extensions window opens the same window, which is the convenient door right after you
install one.

The split is worth knowing, because it tells you where to look for anything: what an
**extension** declares is set in the extension's own window, and what **rio** owns
stays in rio's *Preferences*. So the agent's mode, its prompts and its allow-lists are
in *Preferences ▸ Agent* — those are rio's own mechanisms — while the key and the
server belong to the provider and are set here.

There is no OK and no Cancel and nothing to apply: each setting is stored on the
machine the core runs on as you set it — the one exception being the API key, which
waits for its **Save** button. The window is not modal, so you can leave it open while
you work; **Close** or `Esc` dismisses it.

### Your API key

The window opens with **Credentials**, and that is where a hosted provider's key
goes. The field is masked; beneath it are **Show key**, **Save** and **Clear**.

- **Save is deliberate.** Unlike the settings below it, the key is *not* written when
  you move away from the field — press **Save**, or `Return` in the field. A key is
  pasted and glanced at before it is committed, so rio waits to be told.
- The field is **blank every time the window opens.** rio keeps your key for the
  provider but never reads it back, so what you see is not what is stored. The note
  under the buttons is what tells you: *A key is stored*, or *No key stored yet* —
  and where to create one, when the provider names a place.
- **Clear** removes the stored key, and is greyed out until there is one to remove.
- **Show key** unmasks what you have typed, for checking a paste. It reveals nothing
  that was already stored.
- Because the field is masked, its right-click menu offers *Paste* and *Select All*
  only: you can put a key in, but not lift one back out as plain text.

The key is never written into `prefs.json` or any other settings file. It lives on
its own, mode `0600`, in rio's data directory — see
[preferences](preferences.md#where-everything-lives) for the exact path.

*(API key)* in the provider picker means a provider **can take** one, not that it
must have one; the offline ones are marked *(offline)*. A server of your own usually
needs none — leave it unset and rio sends no authorization header at all.

**The agent runs in the core, not in the window.** With a remote core, the turn is
made on the server and the key is stored there — which is a real consideration if
that machine isn't yours. rio says so plainly when you connect. See
[working remotely](remote.md).

### Settings a provider declares

Below the credentials sits the rest — where its server is, how big a reply may be,
how long a turn may take. The form is built from **what that provider declares**, so
rio keeps no list of its own to go stale: the sections, the fields and the muted
explanation under each come from the provider. A choice is a drop-down; anything else
is a field you type in.

**Each of these is saved as you make it** — a drop-down the moment you pick from it,
a field when you press `Return` or move away from it — into that provider's settings
file above. A provider that declares nothing says so, and the window is then its
credentials alone.

## Running a model of your own

The **OpenAI-compatible** provider reaches hosted ChatGPT and a server of your own
through exactly the same path — Ollama, llama.cpp / llama-server, llama-swap, vLLM and
LM Studio all speak that protocol. Only the URL differs, and a key is usually not
needed at all.

1. Install the **openai** extension and **restart rio**.
2. Pick **OpenAI-compatible** in ***Settings ▸ Agent Provider***.
3. Open ***Extensions ▸ OpenAI-compatible…***.
4. Set **Server URL** to your server's API base, with no trailing path:
   `http://your-box:11434/v1` for Ollama, `http://localhost:8080/v1` for
   llama-server. rio appends `/chat/completions` and `/models` itself — paste one of
   those on the end, or a trailing slash, and it trims them for you.
5. Click **⟳ Refresh from provider** beside **Model**. The list is replaced by what
   *that* server actually offers. Pick one.
6. Leave **API key** alone, at the top of the same window. With none stored rio sends
   no authorization at all and lets the server decide, which is what a server of your
   own normally wants.

rio refuses a turn before it starts in exactly one case: **no key and no server URL of
your own**, because then it really is hosted OpenAI, which really does need a key.

Two settings matter more than usual for a server of your own:

- **Request timeout (ms)** bounds the **whole** turn, not the idle time in it. A
  server that loads a model on demand, or a long generation on modest hardware, needs
  a generous value.
- **Extra request JSON** is a JSON object merged into every request — for whatever
  your server understands that rio has never heard of: `temperature`, `top_p`, or
  llama.cpp's and vLLM's `chat_template_kwargs`. Any field rio sends itself is refused
  here, with a message naming the setting to use instead.

The two **Advanced** URLs stay blank unless your server keeps its completions and its
model list somewhere other than under one base.

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

The transcript is read-only, but you can select in it and right-click for *Copy* —
useful for lifting a path or a command out of a reply. The box you type in has the
full editing menu, as does the instruction box of
[Change with Agent…](#changing-just-the-selection); see
[right-click menus](getting-started.md#right-click-menus).

## Thinking, shown apart from the answer

Some models stream their reasoning separately from their reply — llama.cpp's and
vLLM's thinking builds, and the DeepSeek-derived ones. rio shows it in the chat under
a muted `· thinking` marker, indented and visibly not the answer.

It is **never part of the answer, and never sent back to the model**: rio shows it and
forgets it, so it costs nothing on the next step of the turn. Once the answer begins,
the thinking stays above it in the transcript rather than vanishing — a turn that took
several steps can be read back in the order it happened.

To stop seeing it, set **Reasoning** to *Hide it* — the OpenAI-compatible provider
offers that in [its settings](#settings-a-provider-declares). Some servers can also be
told not to produce any in the first place: on llama.cpp,
`{"chat_template_kwargs":{"enable_thinking":false}}` in **Extra request JSON** does it.

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
rather than skimmed. That view is read-only — right-click it to copy a step out of
it — and the chat pane keeps the decision:

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

- **View rio's instructions…** opens the shipped text, rendered, read-only — you can
  still select in it and right-click for *Copy*. The line above it names the file, so
  you can also open it in any editor you like.
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

- [Extensions](extensions.md) — installing Claude, the OpenAI-compatible provider, or
  another one.
- [Preferences](preferences.md) — where the key, prompts and allow-lists live.
- [Working remotely](remote.md) — what changes when the core is on another box.
