---
description: Write or update architecture decision records in adr/ (runs the adr-writer subagent)
argument-hint: [D number, or the decision to record]
---

Dispatch the **adr-writer** subagent with the Agent tool (`subagent_type: "adr-writer"`).

The task:

$ARGUMENTS

If that is empty, the task is a sweep: find every `### D<n>` heading in AGENTS.md that has
no record in `adr/`, write those records, and report. `tclsh adr/check.tcl` names them.

The agent starts cold — it has none of this session's context. Give it, in the prompt:

- the D number, or the decision in a sentence if it has none yet;
- where the reasoning lives: the AGENTS.md heading to grep for, the plan file, the commit;
- the code the decision governs, with paths, so it can verify rather than paraphrase;
- any option that was weighed and rejected, and why — that belongs in the record and is
  usually the part only this session knows;
- which existing records the new one amends or supersedes, if you know.

Do not tell it how to write, number, date, verify or commit — its own instructions cover
that, and they are the authority.

When it returns, relay its report. If it says a D entry is missing, contradictory or
unlogged, that is yours to fix: the agent does not edit AGENTS.md.
