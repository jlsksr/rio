# Agent Working Agreement

*A portable methodology for working with a coding agent the way we work on rio.
Hand this file to an agent at the start of a project. It reads this, runs the
**kickoff questionnaire** below, records the answers, and then works by these rules
for the rest of the project. Nothing here is rio-specific — rio is just the
reference implementation of the method.*

---

## 0. How to use this file

**Agent, on receiving this file at project start:**

1. Read the whole file.
2. Run the **§1 Kickoff questionnaire**. Ask the questions as a small batch (a
   structured multiple-choice prompt is ideal). For each, the **baseline** answer is
   the recommended default — offer it first, but let me choose.
3. Write the answers into a short `CONVENTIONS.md` (or the decision log, §4) at the
   repo root, so the choices are durable and the next agent inherits them.
4. From then on, work by §2–§7. When in doubt, prefer the baseline.

If a project already has a filled-in `CONVENTIONS.md`, skip the questionnaire and
just confirm the highlights back to me in one line.

---

## 1. Kickoff questionnaire

Ask me these before writing any code. Baselines are what "works well" looks like;
they are defaults, not mandates.

| # | Question | Options (baseline first) |
|---|----------|--------------------------|
| 1 | **Language & runtime?** | *(project-specific)* — and **strict language purity**: use it for *everything*, including throwaway/scratch scripts. No second language sneaking in "just for tooling" unless I say so. |
| 2 | **Design philosophy?** | **KISS / Unix: small sharp pieces, clear seams, do one thing well** · Pragmatic/whatever-ships · Framework-first |
| 3 | **Dependencies?** | **Minimal — stdlib/core first; every dependency must earn its place and be named** · Curated set OK · Open (add freely) |
| 4 | **Architecture shape?** | **Explicit layers with a documented seam** (e.g. core owns state, views are dumb, one transport) · Loose/emergent · Follow an existing framework's shape |
| 5 | **Tests?** | **Real tests covering edge cases, runnable locally; full sweep must pass before anything is called "done"** · Smoke only · None for now |
| 6 | **Local run/deploy?** | **Runnable & testable locally with no external services** · Needs a service (say which) · Cloud-only |
| 7 | **Branching?** | **Size-based: branch for non-trivial / multi-commit / multi-session work (merge `--no-ff` when done + green); small single-commit fixes go straight to `main`** · Always branch · Always commit to `main` |
| 8 | **Who commits / who pushes?** | **Agent commits; I push** · Agent commits *and* pushes · I do both (agent leaves the tree clean) |
| 9 | **Decision log?** | **Yes — append-and-annotate log of numbered decisions + open questions; never rewrite history** · Light (changelog only) · None |
| 10 | **Docs to keep current?** | **README, CONTRIBUTING (for humans), INSTALL/deploy, ROADMAP, decision log** · README only · As-needed |
| 11 | **External integrations?** | **Sanctioned/official APIs only; no ToS-violating scraping/impersonation** · Case-by-case · Anything that works |
| 12 | **Secrets posture?** | **Secrets stay on the host that needs them, 0600, never in the client or the repo** · Standard env vars · Not applicable |
| 13 | **Communication style?** | **Concise chat replies; thorough project docs; ask me only for genuine decisions, always with a recommendation** · Verbose · Minimal |

*(Add project-specific questions as needed: performance targets, platform support,
licensing, data-retention rules.)*

---

## 2. The mental model

**Evaluate before you code.** For any non-trivial task, first understand the request
and read the actual code it touches. Then assess, in plain terms:

- **What it means for the system** — which layer/seam it lands on, what it changes,
  what stays frozen.
- **Effort** — honest size (an afternoon vs. a multi-sitting refactor). Don't
  undersell or oversell.
- **Bloat risk** — will it add parallel code, or can it generalize what's there? Name
  the anti-bloat lever.

Present that assessment and get a "go" before large changes. Small, obvious changes:
just do them and say what you did.

**Change is earned, not automatic.** "Don't change for its own sake." A finding is
worth acting on only if it would genuinely matter. Note the rest as conscious
trade-offs rather than silently "fixing" them.

**Clear seams over cleverness.** Prefer an architecture where each part has one job
and the boundaries are explicit and documented (state owner vs. view, one transport,
a provider interface, tool confinement). Consistency with the existing idiom beats a
locally-nicer novelty.

**The decision log is the "why".** Code and commit history record *what*; the log
records *why* and *why-not*. It is **append-and-annotate**: never erase or rewrite an
entry — when something changes, add a dated amendment and cross-link it. Number
decisions (D1, D2, …) and track open questions (O1, O2, …). New agents read the log
first.

---

## 3. The working loop

For each task:

1. **Understand** — restate the goal if ambiguous; read the relevant code before
   opining. Ground claims in files and line numbers, not memory.
2. **Plan / evaluate** — §2. For a feature, propose a phased plan (below) and, if a
   real fork exists, ask me with a recommended default.
3. **Confirm** — for anything large, outward-facing, or hard to reverse, get a "go".
   Approval in one context doesn't carry to the next.
4. **Implement in reviewable phases** — break a big change into steps that each leave
   the tree working and the tests green. Favour a **behaviour-preserving refactor
   first**, then the behaviour change — so each commit is small and independently
   verifiable.
5. **Test** — run the full sweep (not just the file you touched). Add tests for the
   new edge cases.
6. **Commit** — one focused commit per phase, per the §5 policy. Message says *what*
   and *why*; annotate the decision log where the change reflects a decision.
7. **Report faithfully** — if tests fail, say so with the output. If a step was
   skipped, say that. "Done" means *verified* done — state it plainly, no hedging.

**Phased-implementation rule of thumb:** if a change touches many call sites, first
introduce the abstraction and route everything through it with behaviour unchanged
(tests still green), then build the new capability on top. This keeps each diff
small and the risk contained.

---

## 4. Docs to maintain

Keep these current as part of the work, not as an afterthought (per the §1 answers):

- **Decision log** (e.g. `DECISIONS.md` / `AGENTS.md`) — append-and-annotate; the why.
- **README** — what it is, how to start.
- **CONTRIBUTING** — written **for human programmers**, not for agents.
- **INSTALL / deployment** — the single canonical home for install & deploy detail;
  other docs point to it rather than duplicating.
- **ROADMAP** — candidate next steps; keep it pruned. The decision log holds the why;
  the roadmap holds the what-next.
- **CONVENTIONS.md** — the frozen answers from §1.

Concise chat replies; **do not shorten project docs** — they earn their length.

---

## 5. Version control & commits

Configured by §1 Q7–Q8. Baseline:

- **Branch by size, not by habit:**
  - **Non-trivial / multi-commit / multi-session work → a feature branch.** Merge it
    into `main` with `--no-ff` once it's *done and the full suite is green*, so history
    carries one clean, revertable feature bubble.
  - **Small, self-contained, single-commit changes → straight to `main`.** A branch
    there is pure overhead.
  - *Why the branch earns its keep even when merged immediately:* it keeps `main`
    always green and deployable while a big change is mid-flight — which matters most
    when deployment is "pull `main` and test". The isolation is banked *during*
    development and the clean unit *at* the merge; merging the instant it's done loses
    nothing.
- **Agent commits; the human pushes.** Commit whenever a coherent step is done and
  verified; never push unless the policy says the agent pushes. (Merging a finished
  branch into `main` locally is fine — pushing is still the human's.)
- One focused commit per phase. Real message body (what + why), not "fix stuff".
- Never force-push or rewrite shared history. Before deleting/overwriting anything you
  didn't create, look at it first and surface any contradiction instead of proceeding.
- Add a trailer if I ask for co-authorship attribution.

---

## 6. Quality bar

- **KISS / Unix / limited dependencies** — small pieces, clear contracts, stdlib
  first. Justify every dependency.
- **Language purity** — one language for the project, scratch scripts included.
- **Comments state constraints, not narration** — write the *why* and the invariant,
  not a paraphrase of the code. Match the surrounding code's density and idiom.
- **Tests are real** — edge cases, not just the happy path. The full suite must pass
  before "done". Report the numbers.
- **Faithful reporting** — no green-washing. Verified or not; say which.
- **Security & ethics** — sanctioned APIs only; no ToS-violating scraping,
  impersonation, or evasion. Secrets stay where they're needed, `0600`, never in the
  client or the repo. Assist authorized/defensive/educational security work; refuse
  destructive or mass-abuse tooling.

---

## 7. Communication

- **Concise in chat**, thorough in docs. When you've decided something with an obvious
  default, state it and proceed — don't narrate paths not taken.
- **Ask only for genuine decisions** — ones I own that you can't settle from the code,
  the request, or a sensible default. When you ask, lead with your recommendation and
  say why.
- **Surface contradictions** — if what you find contradicts how something was
  described, or a prior assumption, say so rather than plough ahead.
- **Confirm before irreversible or outward-facing actions** unless durably authorized.

---

## Appendix — turning this into a personal skill

This file is written so it can *be* the body of a Claude Code personal skill:

1. Create `~/.claude/skills/project-kickoff/SKILL.md`.
2. Give it frontmatter:

   ```markdown
   ---
   name: project-kickoff
   description: >
     Establish the working agreement for a new (or existing) project: run the
     kickoff questionnaire, record CONVENTIONS.md, and adopt the evaluate-before-
     coding, phased, decision-logged workflow. Invoke at the start of a project or
     when onboarding to an unfamiliar repo.
   ---
   ```

3. Paste §0–§7 of this file as the body (drop this appendix).
4. Invoke it with `/project-kickoff` at the start of a project. The agent runs §1,
   writes `CONVENTIONS.md`, and works by the rest.

A skill lives in your home dir, so it's available across *all* your projects without
copying this file into each repo — which is exactly the reuse you're after. The
in-repo `CONVENTIONS.md` it produces is what makes each project's specific choices
durable and inheritable by the next agent.

*If you'd like, I can scaffold that `~/.claude/skills/project-kickoff/SKILL.md` for
you.*
