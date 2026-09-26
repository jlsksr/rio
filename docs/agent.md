# The agent

The chat column on the right, where an AI model works on your project: reading
files, proposing edits, and running commands. Anything that changes something
waits for your approval.

`Ctrl+Shift+A`, or ***View ▸ Agent***, shows and hides the pane.

## What the agent may do without asking

**Reading is free. Writing waits for you. Commands always wait for you.**

The agent may look around your project as much as it likes: list folders, read
files, read the files you have open including your unsaved edits. Each read is
shown in the chat as it happens. It cannot change a file or run a program until
you approve that one action in the pane.

## Choosing a provider

rio ships one provider: **echo**, an offline stub that needs no key and no
network. It exists so the chat pane works and can be tested. It is not a model.

Real providers install as extensions from ***Extensions ▸ Browse…***:

| Provider | Talks to |
| -------- | -------- |
| Claude | the official Anthropic API |
| OpenAI-compatible | hosted ChatGPT, *or* any server that speaks the same protocol — Ollama, llama.cpp / llama-server, llama-swap, vLLM, LM Studio |

Which server the OpenAI-compatible provider uses is a setting, not a different
extension: see [running a model of your own](#running-a-model-of-your-own).

A provider runs inside the core, and the core loads the providers it has when it
starts, so **restart rio after installing one**. Until you do, that extension's
row in the Extensions window says so instead of offering its settings.

To pick the live provider, use ***Settings ▸ Agent Provider*** or
*Preferences ▸ Agent*. The provider's own key, server and model are set in
[its own window](#a-providers-own-settings) instead. See
[extensions](extensions.md) for adding a repository to install from.

## Choosing a model and an effort

The strip along the bottom of the agent pane names what you are talking to, as
in **Claude · Sonnet 5 ▾**. Click it to change that. It holds the choices worth
changing between turns; everything else is in [the provider's settings
window](#a-providers-own-settings).

| Section | Sets |
| ------- | ---- |
| Provider | The same choice as ***Settings ▸ Agent Provider***, next to the rest of the decision. |
| Profile | Which of that provider's saved configurations to run on, when it keeps more than one. See [profiles](#profiles-several-setups). |
| Model | The models that provider offers. **Other…** takes any model id you type; **⟳ Refresh from provider** replaces the list with what your key, or your local server, can actually reach now. |
| Effort | How much thinking to ask for. **Provider default** sends no such request at all. |

The shipped model list is short and goes stale. **Other…** and **⟳ Refresh from
provider** are the way round that.

Not every model accepts an effort: `gpt-4o`, most local servers and Claude Haiku
refuse it. For Claude, a refresh also learns which models take one and which
values they take, so the menu then offers only what the model you picked
accepts, and a model that takes none is sent none instead of losing the turn to
an error.

Anything not at its default is spelled out in the strip. Hover over it for the
full state, including the raw model id and the profile name.

Each provider remembers its own choices in a plain file:

```
$XDG_CONFIG_HOME/rio/agent/providers/claude.conf
```

```
model = claude-opus-5
effort = high
```

Which keys it holds depends on the provider: whatever it declares in its
settings window lands there. The API key never does; it is kept apart from every
settings file. A provider that keeps [profiles](#profiles-several-setups) has
one such file per profile in a folder of its own, and the file above then
records only which profile is live.

These files sit on the **core's** machine. With a remote core, the model list is
what that core can reach, and the files are on the server.

## A provider's own settings

***Extensions ▸ `<provider>`…*** opens the window where a provider's key and
everything else it lets you set are configured. With Claude and the
OpenAI-compatible provider installed, that is ***Claude…*** and
***OpenAI-compatible…***. The provider's row in the Extensions window opens the
same window, which is the convenient door right after installing one.

Where a setting lives:

| Belongs to | Set in |
| ---------- | ------ |
| The extension — key, server, model, limits | The extension's own window, under *Extensions* |
| rio — the agent's mode, prompts, allowed commands | *Preferences ▸ Agent* |

There is no OK and no Cancel. Each setting is stored on the core's machine as
you set it, the API key excepted: that waits for its **Save** button. The window
is not modal, so you can leave it open while you work. **Close** or `Esc`
dismisses it.

### Your API key

The window opens with **Credentials**, under the Profile row where there is one.
The field is masked; beneath it are **Show key**, **Save** and **Clear**.

- **Save is deliberate.** Unlike the settings below it, the key is not written
  when you move away from the field. Press **Save**, or `Return` in the field.
- **The field is blank every time the window opens.** rio keeps your key but
  never reads it back. The note under the buttons is what tells you: *A key is
  stored*, or *No key stored yet*, and where to create one when the provider
  names a place.
- **Clear** removes the stored key. It is greyed out until there is one.
- **Show key** unmasks what you have typed, for checking a paste. It reveals
  nothing already stored.
- The field's right-click menu offers Paste and Select All only: you can put a
  key in, but not lift one out as plain text.
- For a provider that keeps [profiles](#profiles-several-setups), **the key
  belongs to the profile**. Switch profiles and you are looking at a different
  key — which is how a local profile can have none while your hosted one has
  yours.

The key is never written into `prefs.json` or any other settings file. It lives
on its own, mode `0600`, in rio's data directory — see
[preferences](preferences.md#where-everything-lives) for the path.

*(API key)* in the provider picker means a provider **can take** one, not that
it must. Offline ones are marked *(offline)*. A server of your own usually needs
none: leave it unset and rio sends no authorization header.

**The agent runs in the core, not in the window.** With a remote core, the turn
is made on the server and the key is stored there. That matters if the machine
is not yours; rio says so when you connect. See [working remotely](remote.md).

### Settings a provider declares

Below the credentials sits the rest: where its server is, how large a reply may
be, how long a turn may take. The form is built from what that provider
declares, so the sections, the fields and the explanation under each come from
the provider rather than from a list rio keeps. A choice is a drop-down;
anything else is a field you type in.

Each is saved as you make it, into the settings file of the profile you are on:
a drop-down when you pick from it, a field when you press `Return` or move
away. A provider that declares nothing says so, and the window is then its
credentials alone.

### A setting that names a file

One setting can be too big for a one-line field. The provider then makes it a
file name with an **Edit…** button beside it. The OpenAI-compatible provider's
**Extra request JSON** is the one that does this today.

**Edit…** opens that file as an ordinary tab in rio, and creates it first if it
does not exist. A new one starts as `{}`, which sends nothing. Leave the name
blank and rio picks one for this profile.

Two things follow from it being a file:

- It may be several lines, indented and readable.
- It is read fresh from disk at the start of every turn, so a saved edit takes
  effect on the next one. An edit you have not saved is not in the file.

Because it is read that late, it is checked that late. If the file no longer
parses the turn stops and says so. For the OpenAI-compatible provider:

- it must be a JSON object — `{"temperature": 0.2}`, not a list or a bare value;
- it may not set a field rio sends itself (`model`, `messages`, `stream`,
  `tools`, the token-cap field, the effort field). The refusal names the setting
  to use instead.
- Blank, or no file at all, sends nothing extra.

The name is a plain file name kept next to that provider's profiles; a path with
separators in it is refused. Use a symlink to keep the file elsewhere.

### Profiles: several setups

A provider may keep more than one complete configuration. The OpenAI-compatible
one does. Each configuration is a **profile**: its own server, its own model,
its own limits, and its own API key. Switching to a profile that points at a
server on your own machine therefore never sends a hosted vendor's key to it.

Where a provider keeps profiles, its settings window opens with a **Profile:**
row above everything else, because it decides what the rest of the window shows.

- The drop-down switches profiles. Everything below is re-read from the one you
  pick, including the model list a **⟳ Refresh** last found.
- **Manage…** opens a small window listing them all, with the live one marked.

| In Manage… | Does |
| ---------- | ---- |
| **Switch to** | Makes the selected profile the live one. |
| **New…** | Starts a profile from the provider's shipped defaults. |
| **Duplicate…** | Copies the selected one, extra-request file included, so editing the copy never changes the original. |
| **Rename…** | Renames the selected one. |
| **Delete…** | Asks first, defaulting to *No*, then deletes that profile's settings and any extra-request file of its own. |

New… and Duplicate… ask for a name and then switch to what they made. **The last
profile cannot be deleted**: settings have to live in one, so there is always
exactly one left.

Names are yours to choose: a profile name may use letters, digits, spaces and
`.` `_` `-` `(` `)`, so `Qwen3.8 27B (local)` is fine. Anything that could name
a different file is refused: path separators, `.` and `..`, a leading dot, and a
leading or trailing space.

Day to day you switch profiles from the [strip at the bottom of the chat
pane](#choosing-a-model-and-an-effort). Making one stays here.

#### What you start with

On its first run the OpenAI-compatible provider writes three profiles:

| Profile | Points at |
| ------- | --------- |
| `ChatGPT` | `https://api.openai.com/v1`, model `gpt-4o` — add your key and go |
| `Qwen3.8 27B (local)` | `http://127.0.0.1:1080/v1` — an example of a server of your own |
| `Qwen3.8 Flash Next (local)` | the same server, a different model |

The two local ones are examples, not a claim about your machine: that port is
llama-swap's usual one, and those were the model names it was serving. Point
them at your own server and model, or delete them. They carry no API key, a much
larger token cap, and their thinking is configured through the [extra-request
file](#a-setting-that-names-a-file) rather than the **Effort** setting, because
llama.cpp and most compatible servers refuse the standard effort field. Both
name the same empty key store, so a key saved while either is live counts for
both.

They are written once. An edited one keeps your edits and a deleted one stays
deleted, upgrade or not.

If you used this provider before it had profiles, your settings are not
replaced. They become a profile called `Current settings`, and it stays live.

## Running a model of your own

The OpenAI-compatible provider reaches hosted ChatGPT and a server of your own
by the same path. Only the URL differs, and a key is usually not needed.

1. Install the **openai** extension and restart rio.
2. Pick **OpenAI-compatible** in ***Settings ▸ Agent Provider***.
3. Open ***Extensions ▸ OpenAI-compatible…***.
4. Give your server a profile of its own, so your hosted setup stays intact:
   pick one of the two local examples in the **Profile:** row, or press
   **Manage…** and then **New…** and name it after your machine. Everything from
   here lands in that profile alone.
5. Set **Server URL** to your server's API base, with no trailing path:
   `http://your-box:11434/v1` for Ollama, `http://localhost:8080/v1` for
   llama-server. rio appends `/chat/completions` and `/models` itself, and trims
   either of those, or a trailing slash, if you paste one.
6. Click **⟳ Refresh from provider** beside **Model** and pick from what that
   server actually offers.
7. Leave the API key alone. With none stored rio sends no authorization at all
   and lets the server decide.

From then on, moving between your server and hosted ChatGPT is picking a profile
in the strip at the bottom of the chat pane.

rio refuses a turn before it starts in one case only: no key **and** no server
URL of your own, because then it really is hosted OpenAI, which needs a key.

Two settings matter more than usual for a server of your own:

- **Request timeout (ms)** bounds the whole turn, not the idle time in it. A
  server that loads a model on demand, or a long generation on modest hardware,
  needs a generous value.
- **Extra request JSON** names a [file](#a-setting-that-names-a-file) holding a
  JSON object merged into every request: `temperature`, `top_p`, or llama.cpp's
  and vLLM's `chat_template_kwargs`. Press **Edit…** to write it.

Leave the two **Advanced** URLs blank unless your server keeps its completions
and its model list under different bases.

## A turn, step by step

Type a request and press **▶**, or `Enter`. The agent streams its reply into the
pane, and on the way it may do three kinds of thing:

| Step | What you see |
| ---- | ------------ |
| **Read** | "listing `src/`", "reading `parser.tcl`". These happen at once and are shown as they go. |
| **Propose an edit** | A diff, and two buttons: **Approve** or **Reject**. On approval rio applies the change and, by default, saves it. |
| **Propose a command** | The exact command, before anything runs, and the same two buttons. Approved commands run confined to your project and are time-boxed. |

A complex edit opens in the full side-by-side
[compare view](editor.md#comparing-two-documents) instead of inline. Turn that
off with *Preferences ▸ Agent ▸ Compare complex edits* if you prefer everything
inline.

A turn runs until the agent is finished; there is no step limit. While it works,
the **▶** button becomes **■ Stop**, which ends the turn where it stands.
Nothing half-applied is left behind, because every change had to pass the gate
first. The request already sent to the provider is still paid for.

The transcript is read-only. You can select in it and right-click for *Copy*,
which is useful for lifting out a path or a command. The box you type in has
the full editing menu, as does the instruction box of
[Change with Agent…](#changing-just-the-selection). See
[right-click menus](getting-started.md#right-click-menus).

## Thinking, shown apart from the answer

Some models stream their reasoning separately from their reply: llama.cpp's and
vLLM's thinking builds, and the DeepSeek-derived models. rio shows it under a
muted `· thinking` marker, indented and visibly not the answer.

It is never part of the answer and is never sent back to the model, so it costs
nothing on the next step of the turn. Once the answer begins, the thinking stays
above it in the transcript, so a turn that took several steps can be read back
in order.

**To stop seeing it**, set **Reasoning** to *Hide it* in
[the provider's settings](#settings-a-provider-declares).

**To stop the server producing any**, on llama.cpp, put this in that profile's
[extra-request file](#a-setting-that-names-a-file):

```
{
  "chat_template_kwargs": { "enable_thinking": false }
}
```

The same file is where you ask for *more* thinking on a server that wants it
there rather than through **Effort**. That is how the two shipped local profiles
are set up.

## Changing just the selection

Select text in the editor, right-click it and choose **Change with Agent…**.

A small window names what you selected, as in *Selection: parser.tcl, lines
12–20*, and takes your instruction: "rename `tok` to `token`", "make this loop
iterative". `Enter` sends it, `Shift+Enter` starts a new line, **Cancel** or
`Esc` drops it. A selection that ends at the very start of a line does not count
that line.

Sending brings the agent pane into view, because the review happens there. Your
request shows as an ordinary **You** message, with a muted line underneath
naming the selection.

**The agent can change the selected text and nothing else.** For that one turn
it is handed a single changing tool, which replaces exactly the selected text.
It cannot edit another part of the file, touch another file, create one, or run
a command. It can still read your project for context. In plan mode it can only
read and present a plan, as always.

The change goes through the usual gate: a diff with **Approve** and **Reject**,
the compare view for a complex one, and no question at all under auto-accept.
The editor stays live while you decide:

- if you changed the **selected text itself** in the meantime, the edit is
  refused and nothing is replaced — select it again and ask again;
- if you only edited above it, so the text merely moved, the edit still lands on
  it, as long as that text appears only once in the file.

One `Ctrl+Z` takes the whole replacement back. A file-backed buffer is saved the
way any approved agent edit is; an untitled one works too, and is never saved.

The restriction lasts for that turn. The next message you type in the chat is an
ordinary request again.

**When the entry appears:** only while a provider other than Echo is selected,
and only while *Preferences ▸ Agent ▸ "Show “Change with Agent…” in the editor's
context menu"* is ticked, which it is by default. The entry is greyed out with
nothing selected, and while a turn is working or waiting for your approval.

## Planning before building

For anything bigger than a small fix, ask to see the plan first.

**Just ask.** "Plan this first", "what would you do?", "show me the plan before
you touch anything". The agent can present a plan in any mode, and offers one
unprompted before a large or hard-to-reverse change.

**Plan mode** is the stronger version. Set the agent's mode to **Plan** and
describe the job as usual. The mode is on the menu at the top of the chat pane,
on ***Settings ▸ Agent Mode***, and in *Preferences ▸ Agent*. While plan mode is
on, the agent is handed no editing and no command tools at all: it can only
read your project and present a plan. Asking for a plan is a request; plan mode
is a restriction.

The plan opens in the middle of the window, where the editor sits, formatted the
way this manual is. That view is read-only; right-click to copy a step out of
it. The chat pane keeps the decision:

| Button | Does |
| ------ | ---- |
| **Approve ▾** | Starts the work, and asks how: *review each edit*, or *auto-accept edits* from here on. |
| **Edit plan** | Opens the plan as an ordinary file, so you can rewrite a step, delete one or add a constraint before approving. The agent is given your version, and you do not have to save it first. |
| **Reject** | Starts nothing, and leaves plan mode on if that is where you were. Say what you want different and let it try again. |
| **Plan** | Reopens the plan if you closed it. `Esc` or **× Close plan** puts the editor back while you think. |

Every plan is saved in your project under `.rio/plans/`, with the date and its
title in the file name, including the ones you reject. They are plain Markdown:
keep them, read them later, or delete the folder. Add `.rio/plans/` to your
`.gitignore` if you would rather they did not travel with the code. That file is
the plan itself, which is why **Edit plan** simply opens it.

Plan mode is part of rio, not of one model's API, so it works the same whichever
provider you have installed.

## Approving less often

Two ways to be asked less. They are separate settings.

**Auto-accept edits** is the agent's third mode, beside *Plan* and *Review*: it
applies proposed **edits** without asking. Useful while you watch a long
refactor and review it in git afterwards. It never covers commands. Set it from
the menu at the top of the chat pane, from ***Settings ▸ Agent Mode***, from
*Preferences ▸ Agent*, or from a plan's own **Approve ▾** button.

The three modes are exclusive, and the menu always shows which one is live.

**Allowed commands** is standing approval for particular commands, which you
write yourself. When the agent proposes a command, the approval bar carries an
**Always allow ▾** button offering two rules:

- **the program** — a one-word rule such as `pytest` trusts every run of it;
- **that exact command** — `git status` trusts only commands starting that way.

Each rule goes into one of three lists, and you pick which:

| Scope | Applies |
| ----- | ------- |
| All projects | everywhere, for every provider |
| This project | only in the folder you have open, stored in the project's `.rio/` |
| A chosen provider | only while that provider is the live one |

A command runs unasked if any active list allows it. Review, add and remove
rules in ***Preferences ▸ Agent ▸ Allowed commands…***. All three lists are
plain text files you can also edit by hand, listed in
[preferences](preferences.md#where-everything-lives). Removing a rule makes that
command ask again.

## Telling the agent how you work

***Preferences ▸ Agent ▸ Agent Prompts…*** lists everything the agent is told,
in the order it is composed. Five layers, all plain Markdown, all optional
except the first:

| Layer | Applies to | Lives | Yours? |
| ----- | ---------- | ----- | ------ |
| rio's instructions | every turn | ships with rio | read it; replace it if you want |
| System | every project, every provider | with your rio settings | yes |
| Per-provider | only while that provider is running | with your rio settings | yes |
| Project | the folder you have open | `.rio/agent.md` in the project | yes |
| Plan mode | only while the agent is in Plan mode | ships with rio | read it; replace it if you want |

Your three open in rio's own editor and are **added on top of** rio's, never
replacing them. An empty prompt is a normal state, and a badly worded one cannot
break the agent's tool contract.

Which layer to use:

| Instruction | Layer |
| ----------- | ----- |
| "prefer small commits", "this codebase is POSIX shell" | System — it shapes whichever model runs |
| Facts about one codebase | Project — it travels with the code in git |
| Quirks of one model | Per-provider — switching models does not drag them along |

Beside each layer the list says what it is doing right now: *in effect now*,
*empty*, *not created yet*, *not in effect now*.

### Reading rio's own instructions

The first and last layers are rio's, and they are not hidden from you. They are
what makes the agent behave the same whichever provider you install: the tool
contract, how to work in someone else's codebase, how to run commands, what to
verify before saying something works, and in plan mode what a plan should
contain.

| Button | Does |
| ------ | ---- |
| **View rio's instructions…** | Opens the shipped text, rendered, read-only. Right-click for *Copy*. The line above it names the file, so you can open it in any editor. |
| **Show the whole prompt…** | Renders every active layer joined together: the exact string the provider is sent, nothing summarised. |
| **Make my own copy…** | Writes that text to your own settings as an editable file and opens it. Your copy then replaces rio's for that layer, and rio's later improvements no longer reach it. Delete the file to go back. |

The agent runs in the core, so these are the files on the **core's** machine.
With a [remote core](remote.md) the dialog shows that machine's paths.

## HTTPS on an older tcltls

A hosted provider is reached over https, from the core, with the core's
`tcltls`. A `tcltls` older than 1.8 checks that a certificate was issued by a
trusted authority but never that it was issued *for the provider*: any valid
certificate for any host would pass. On such a core the agent refuses https
before it connects, and the error names both ways out:

- install `tcltls` 1.8 or newer on the core's host and restart the core (see
  [INSTALL.md](../INSTALL.md)); or
- if that host cannot be upgraded, tick *Preferences ▸ Network ▸ "Allow https
  without host-name checks (tcltls older than 1.8)"*.

The box is off by default. It changes nothing on a `tcltls` that checks names,
and plain `http://`, such as a local Ollama or llama-server, is never affected.

It is one switch for the whole core: https extension repositories obey the same
box. It is stored on the core's host, in `tls.conf`, and every window attached
to that core sees the same answer. See
[preferences](preferences.md#network-how-the-core-checks-https).

A certificate you [accepted for a
repository](extensions.md#a-certificate-that-isnt-trusted) counts for the agent
too, on the same host and port. The agent has no review of its own.

## What the agent will not do

- Run anything outside the open project, or without your say-so unless you
  trusted that command yourself.
- Act while you are away. There is no cron, no background loop, no unattended
  mode: a turn happens because you asked for one.
- Read your API key from a settings file. It is not there.

## Further reading

- [Extensions](extensions.md) — installing Claude, the OpenAI-compatible
  provider, or another one.
- [Preferences](preferences.md) — where the key, prompts and allow-lists live.
- [Working remotely](remote.md) — what changes when the core is on another
  machine.
