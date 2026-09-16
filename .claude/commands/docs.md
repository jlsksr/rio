---
description: Update the user manual in docs/ for what changed (runs the docs-maintainer subagent)
argument-hint: [what changed, or a topic name]
---

Dispatch the **docs-maintainer** subagent with the Agent tool
(`subagent_type: "docs-maintainer"`).

The task:

$ARGUMENTS

If that is empty, work out what changed before dispatching: `git log --oneline -15`, the
last commit that touched `docs/`, and `git diff` over what came after it. Hand the agent
that summary, not the raw diff.

The agent starts cold — it has none of this session's context. Give it, in the prompt:

- what changed, in behaviour terms: the operation, the menu entry, the preference, the
  default;
- the files it should read to verify that behaviour for itself, with paths;
- the decision number behind the change (`D<n>`), if there is one;
- which topics you believe are affected, while making clear it should check for itself;
- anything already known to be wrong or stale in the manual.

Do not tell it how to write, verify or commit — its own instructions cover that, and they
are the authority.

When it returns, relay its report: which topics changed, the verification output, the
commit, and anything it flagged as a defect in rio rather than in the manual. Act on the
flagged defects yourself or raise them with jka; do not send them back to the agent, which
does not own code.
