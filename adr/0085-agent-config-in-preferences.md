# ADR-0085: Agent configuration lives in Preferences

- **Status:** Accepted
- **Date:** 2026-09-09
- **Deciders:** jka
- **Decision log:** AGENTS.md D85

## Context

As the agent grew, the Settings menu gathered a column of agent items: the provider
picker, an API key cascade, Agent Prompts…, Allowed commands…, and two toggles. The
Preferences Agent page already carried all of them.

## Decision

The top-level menu holds fast runtime switches; the Preferences window holds
configuration.

- **Settings menu keeps:** Agent Provider ("which model am I talking to right now"),
  and the quick toggles for auto-accept and compare-complex-edits (later the Agent
  Mode cascade of ADR-0102).
- **Preferences ▸ Agent only:** API keys, Agent Prompts…, Allowed commands….

Nothing was reimplemented; the same dialogs are no longer reachable from the menu.
User-facing messages that named the old location, including provider error messages,
were updated.

## Consequences

- Configuration has one home that can grow (scope selectors, key fields) without
  crowding the menubar, and the menu and window cannot drift apart for these items.
- The general rule applies beyond the agent: a menubar entry must be a quick,
  low-ceremony switch.
