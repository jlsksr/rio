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

## A turn, step by step

You type a request. The agent streams its reply into the pane, and along the way
it may do three kinds of thing:

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

## Loosening the gate, deliberately

Two escape hatches exist, and they are separate on purpose.

**Auto-accept edits** (*Preferences ▸ Agent*, or *Settings ▸ Agent: Auto-accept
edits*) applies proposed **edits** without asking. Useful when you are watching a
long refactor and reviewing in git afterwards. It never covers commands.

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

***Preferences ▸ Agent ▸ Agent Prompts…*** opens three prompts, each plain
Markdown, each optional:

| Prompt | Applies to | Lives |
| ------ | ---------- | ----- |
| System | every project, every provider | with your rio settings |
| Project | the folder you have open | `.rio/agent.md` in the project |
| Per-provider | only while one chosen provider is running | with your rio settings |

They open in rio's own editor and are **added on top of** rio's built-in
instructions — they never replace them, so an empty prompt is a perfectly normal
state and a badly worded one cannot break the agent's tool contract.

The split is about reach. General standing instructions ("prefer small commits",
"this codebase is POSIX shell") belong in the **system** prompt, where they shape
whichever model runs. Facts about one codebase belong in the **project** prompt,
which travels with the code in git. Quirks of one model belong in the
**per-provider** prompt, so switching models doesn't drag them along.

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
