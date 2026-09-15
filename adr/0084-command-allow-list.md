# ADR-0084: Human-authored command allow-lists

- **Status:** Accepted
- **Date:** 2026-09-09
- **Deciders:** jka
- **Decision log:** AGENTS.md D84

## Context

ADR-0083 gates every command, including commands a user runs many times an hour.
Other agent front ends let a user mark a command as trusted. ADR-0083 had also stated
that there would be no allow-list, and ADR-0053 limits autonomy.

## Decision

Users can add commands to an **allow-list**. An allowed command skips the approval bar
and nothing else: it still passes every check of ADR-0083 (redirection guard, confined
working directory, timeout).

This refines ADR-0053 rather than contradicting it. An allow-list written by a person
in advance is standing approval, not autonomy. The rule becomes: no trust decision is
made silently; a human writes every rule.

- **A rule is an argument-vector prefix.** A command matches when its argument vector
  starts with the rule's tokens, compared exactly. There are no shell patterns or globs.
- **Three scopes, matching the prompt layers:** global (`allow.list` in the XDG agent
  directory), per provider (`providers/<name>.allow.list`, active only while that
  provider runs; not for echo), and project (`.rio/allow.list`). Files hold one Tcl
  list per line and can be edited by hand.
- **Union.** A command is allowed if any active layer allows it; there is no precedence.
- `agent.propose` carries `auto 1` for an allowed command, which runs immediately with
  no bar; `auto 0` waits for approval as before.
- On a gated command's bar, "Always allow ▾" offers the program (`argv[0]`, the default)
  or the exact command line, each into a chosen scope, and approves the current
  command. An Allowed commands… manager in Preferences ▸ Agent lists, adds and removes
  rules per scope.

## Consequences

- Repetitive approvals disappear for commands the user trusts.
- A broad rule (the program alone) trusts every invocation of it. The per-click choice
  between program and exact command keeps that decision visible.
- Regular-expression rules, per-directory rules and session-only trust are deferred.
