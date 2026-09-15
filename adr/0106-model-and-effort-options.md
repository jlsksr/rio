# ADR-0106: Model and effort are provider-declared options

- **Status:** Accepted
- **Date:** 2026-09-12
- **Deciders:** jka
- **Decision log:** AGENTS.md D106, D106a–D106e

## Context

The maintainer asked whether the agent pane could switch models and reasoning effort. It
could not. The model was a hard-coded value in each provider extension's configuration,
changeable only by editing the extension's source on the core's disk and lost on reinstall.
Effort did not exist in rio. ADR-0085 had already placed "which model am I talking to right
now" among the fast switches, but only the provider was switchable.

## Decision

**Providers declare their options; the core does not interpret them.**
`register_provider` accepts `-options {list <cmd> set <cmd> ?refresh <cmd>?}`, shaped like
the existing `-key` block. An option descriptor is `{name label hint value free refresh
choices}`. The core normalises descriptors and routes `agent.options.list`,
`agent.option.set` and `agent.options.refresh` by name. No file in `rio-core/` knows what
"model" or "effort" mean, and a provider can add an option with no core or GUI change.

- `free 1` accepts values not in the list, so a model id released after the build can be
  typed in. `refresh 1` lets the provider replace the list with what the endpoint reports;
  for local servers that listing is the only reliable source.
- A refresh is a streaming operation. It acknowledges, then emits `agent.options` with the
  provider name (and `error` on failure); the frontend lists the options again. A failed
  refresh leaves the choices unchanged.
- Choices persist in `$XDG_CONFIG_HOME/rio/agent/providers/<name>.conf`, a conf file the
  core formats and the provider fills with its own keys.
- Effort defaults to `default`, which sends nothing, so requests are unchanged until a user
  chooses otherwise. Parameter spellings are configuration data.
- The control is the chat status strip: a menubutton showing provider, model and any
  non-default option, with the busy indicator beside it rather than over it. The menu is
  built from the declared options. After a change the GUI reads the options back, so it
  shows what the provider accepted.
- `provider-api` became 2.

**Follow-up decisions, from live testing against real endpoints:**

- **Capabilities are per model; ask, do not assume.** Claude Haiku 4.5 rejects the effort
  parameter while Opus and Sonnet accept it. Anthropic's model listing reports effort
  support per model, so a refresh teaches the provider which models accept which values.
  Where a model takes none, only "Provider default" is offered, rio sends nothing, and the
  stored choice is kept for when the user switches back.
- **Request bodies are pure ASCII at the boundary.** Tool schemas were spliced into request
  bodies raw, and one contained an em dash. Tcl's `http` counts `Content-Length` in
  characters and writes to a binary channel, truncating characters above U+00FF to one
  byte. OpenAI rejected the invalid JSON; Anthropic had silently accepted it. The shared
  runtime gained `rio::llm::jascii`, which escapes every non-ASCII character of a finished
  JSON body, applied as the last step in both providers. Because providers call it,
  `provider-api` became 3.
- **When the vendor publishes nothing, learn from the refusal.** OpenAI's reasoning models
  require `max_completion_tokens` instead of `max_tokens`, and reject `reasoning_effort` on
  models that do not support it; the model listing reports neither. On a 400 that names the
  fix, the provider retries the turn once with the corrected request (each repair at most
  once per turn), records the model's requirement in its settings, and sends the right form
  first next time. No tokens are spent on a refused request. Deriving the rule from model
  name patterns was rejected as a hard-coded vendor table.
- **Undeclared charsets decode as UTF-8.** Tcl's `http` decodes a body without a declared
  charset as ISO-8859-1. Plain web directories declare none, so every non-ASCII character
  in an extension fetched from a repository (ADR-0039) had been corrupted at install. Such
  bodies now decode as UTF-8, with a round-trip check that keeps the original decoding when
  the bytes are not valid UTF-8. Existing installs are repaired by reinstalling.

## Consequences

- Model and effort are switchable at runtime, per provider, and survive restarts.
- The core stays free of vendor semantics; the recurring rule is to ask the endpoint or be
  told by it, never to maintain knowledge on a vendor's behalf.
- `agent.options.list` for a provider the core does not have is a `bad_request`, distinct
  from a registered provider that declares no options.
- Offline tests had never included a tool schema in a request body or a charset-less
  fetch; both now have tests, and network paths are also tested over loopback
  (ADR-0116).
