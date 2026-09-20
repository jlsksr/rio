# ADR-0132: A file too big or too binary to open is declined, not read

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** jka
- **Decision log:** AGENTS.md D125

## Context

`file.open` read whatever it was pointed at, whole, and nothing on either side of the wire
questioned the request. The read slurps the bytes, the encoding check expands every one of
them into a Tcl byte list and walks it in interpreted Tcl, the text crosses the channel, and
a Tk text widget takes it with the highlighter behind it. That is the right behaviour for
source and ruinous for a core dump, a database or a build log: the well-formedness pass
alone costs on the order of 150 ms per megabyte, before the widget sees a byte.

The core is single-threaded, so the cost is not confined to the person who caused it. Under
[ADR-0030](0030-always-a-channel-client.md) every frontend is a client of a core, and a
second frontend attached to the same core waits out the whole read. One stray double-click
in the files pane and rio stops answering, for a reason the person who clicked has no way
to guess.

The same size-and-NUL judgement already existed elsewhere. Project search
([ADR-0051](0051-find-in-files.md)) has skipped oversized and binary files since it was
built, using its own inline rule.

## Decision

**Look before reading.** A cheap classifier — one stat, then at most 8 KB off the front —
returns a verdict and the file's size. Over the caller's budget is `too_large`; a NUL byte
in that prefix is `binary`. `file.open` runs it first.

**When the answer is "probably not", ask.** The op declines with an error carrying the size
in words, and the frontend turns that into a yes/no question naming the file and its size,
defaulting to no. A Yes re-issues the same op with an additive `force` parameter, which
skips the guard. rio does not refuse outright, because that would make a file unopenable,
and it does not plough on, because that is the freeze this decision exists to end.

**An error is the right shape for the question.** The op genuinely did not open the file, so
an error reply is honest rather than a smuggled dialog, and it degrades correctly: a
frontend that knows the codes offers the way past them, one that does not shows the message,
which says the same thing in prose. The error taxonomy
([ADR-0113](0113-error-code-taxonomy.md)) gains `too_large` and `binary_file`, and records
that they — with `untrusted_cert` from [ADR-0111](0111-certificate-exceptions.md) — are
codes that are less a failure than an offer. `force` is a parameter an older client simply
never sends, so it gets the guard and no protocol version moves; the additive pattern is
[ADR-0055](0055-core-answers-host-questions.md)'s.

**One rule, two budgets.** The classifier is the single implementation of "too big or
binary", and both the editor and project search call it. What they do not share is the
number: search passes a 2 MB budget, `file.open` 8 MB. A search skipping a file costs
nothing and it walks a whole tree; an editor refusing one costs you the file. A test holds
the two call sites against each other — given the same budget they must reach the same
verdict — so the shared rule cannot be quietly unshared on one side.

**8 MB, in one named place, and not a preference.** It is a judgement about a person's
patience, not a technical ceiling: rio's own largest source file is half a megabyte, so
eight is generous for anything you meant to edit, while a log or a dump lands well the other
side of it. The number is a single named variable in the core, so changing it is one
decision in one place.

**A forced open starts as Plain Text.** Decoding is only half of what makes a huge buffer
crawl; the highlighter is the other half. A buffer opened against rio's advice therefore
gets the `plain` language value of
[ADR-0118](0118-language-picked-by-hand.md), which means the language picker turns
highlighting back on if the file proves fine. No new machinery: the seam for choosing a
language by hand is the seam that switches it off here.

**The prefix rule is a deliberate inexactness.** 8 KB is git's answer, for git's reason: a
check that runs before every open cannot afford to read the file it is deciding about. A NUL
deeper in is not seen, and a test pins that so it stays a trade someone made rather than a
surprise someone finds. Project search keeps a whole-text NUL check after its read, not as a
duplicate of the rule but as the same question asked again where it has become cheap.

## Alternatives considered

- **Capping the well-formedness pass at a prefix**, so that even a forced open is fast.
  Declaring a whole file UTF-8 on the strength of its first megabyte makes the read lossy for
  a file that turns invalid later, and the byte-preserving round-trip of
  [ADR-0022](0022-encoding-line-endings-cursor.md) is worth more than seconds on a path
  nobody reaches by accident.
- **Chunking that pass** so it bails out early without materialising the whole byte list.
  Exact, and worth doing — but it is a performance change to encoding detection, which is not
  what the week before a release is for. ROADMAP.md carries it.
- **A preference for the threshold.** The right answer to "but I did mean it" is the question
  rio now asks, in front of you at the moment you care, not a setting to go and find.
- **Refusing outright.** It would make a file unopenable from rio, which is a worse failure
  than a slow open the user asked for.
- **A second copy of the rule for the editor**, leaving project search's inline one alone.
  That is how two rules drift into disagreeing about what "binary" means.
- **Remembering a forced answer across sessions.** A resumed session asks again. Being asked
  is what makes a session that would otherwise hang on every launch recoverable.

## Consequences

- Opening a large or binary file is a decision the user makes knowingly, and a core serving
  other frontends no longer stalls because one of them clicked the wrong row.
- The forced path is still slow. That is allowed: the size was stated and the answer was yes.
- A frontend that does not handle the two codes still behaves sensibly, but has no way past
  the guard; the message tells the user what happened and nothing more.
- Lazy or windowed loading stays out of scope. The guard makes the cost visible; it does not
  make a 400 MB file editable.
- A file whose first 8 KB are clean text but which holds a NUL later opens as text, and is
  decoded as whatever the encoding check makes of it.
