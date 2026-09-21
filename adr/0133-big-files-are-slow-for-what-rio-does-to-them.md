# ADR-0133: A big file is slow because of what rio does to it, not because it is big

- **Status:** Accepted
- **Date:** 2026-09-20
- **Deciders:** jka
- **Decision log:** AGENTS.md D126

## Context

[ADR-0132](0132-decline-a-file-too-big-to-open.md) had just shipped: over a budget, rio asks
before opening. The maintainer asked whether a warning was really the best answer, since
Notepad++ handles far larger files without complaint, and whether there was a native way to
handle them — no C, no external dependency, no bloat. The premise was worth measuring rather
than defending, and measuring it is the whole decision.

Per megabyte of source text, on one machine under Tcl 8.6, opening a file cost roughly:

| step | ms/MB | share |
| ---- | ----- | ----- |
| whole-buffer syntax highlighting (GUI) | ~1350 | 81% |
| the UTF-8 well-formedness pass, a byte walk in interpreted Tcl (core) | ~164 | 10% |
| JSON encode of the reply plus tcllib's parse of it | ~108 | 6% |
| two line-ending counts over the whole text | ~17 | 1% |
| split, decode and join in the document model | ~11 | <1% |
| **insert into the Tk text widget** | **~5** | **0.3%** |

Tk was never the bottleneck: the widget absorbs 20,000 lines in about four milliseconds.
Notepad++ is not doing something Tk cannot; it is not making three whole-file passes in an
interpreted language. (It has a large-file restriction of its own, and drops highlighting
above it — the same shape as ADR-0132. rio's number was simply far too low.)

## Decision

**Stop doing the unnecessary work.** Each change below deletes a whole-file pass. None adds
a dependency, a thread, or an architecture.

**The UTF-8 verdict is a round trip, not a walk.** The check decodes the bytes as UTF-8,
re-encodes the result, and asks whether the bytes came back identical — two loops in C
instead of one in Tcl with a call per multi-byte character. Nothing malformed survives it:
an overlong form collapses to its short spelling, a truncated sequence decodes to a
replacement character, a byte that is not UTF-8 at all re-encodes wider. It is also a
truer statement of intent than a table walk, because byte-exactness is what
[ADR-0022](0022-encoding-line-endings-cursor.md)'s round trip rests on. The one form a
round trip is more permissive about is a surrogate encoded as three bytes, which re-encodes
to itself; that is still lossless, but "valid UTF-8" is a claim rio makes in a buffer's
metadata and in the manual, so surrogates are excluded by a separate cheap test and the
verdict stays exact. Equivalence with the implementation replaced was demonstrated by a
differential sweep over every short input and over random and real corpora, not assumed.

**Highlighting paints the window, not the file.** This takes up the viewport scoping
[ADR-0032](0032-syntax-highlighting-in-frontend.md) deferred, and the measurement is what
warranted it. The change is mostly a weakening of state that already existed: the cache of
the scan state entering each line now stops at a frontier and claims nothing below it, and
a second pair of marks records which lines actually carry tags, so a scroll repaints only
the newly exposed strip. Because the frontier promises nothing below itself, truncating it
is always legal, which is what lets a pass cap itself without carrying continuation state.
On a file that fits on screen the frontier is the whole file and every line is painted, so
small files run the code they always ran.

Entry states stay exact. A block comment opened on the first line still colours line
400,000, because reaching a line still means having scanned the lines above it. That scan
is real, but it is chunked and yields to the event loop instead of blocking, so colour
streams in. Scrolling reaches it through Tk's `-yscrollcommand`, which is also where the
wheel, the scrollbar, programmatic `see`, vi's jumps and stepping through find results all
arrive: one seam, not five. The scroll machinery ADR-0032 expected this would need turned
out to be a single line.

**The document crosses the channel in chunks.** With the first two changes made, most of
what remained was JSON parsing, and it was quadratic in the length of one string: tcllib's
pure-Tcl parser degrades on a single enormous JSON value, and `buffer.text` was handing it
the whole document as exactly that. `buffer.text` now accepts an optional start line and
returns about 256 KB at a time with a next line and an end-of-file flag. Without a start
line it returns the whole document as before, which is what the agent's tool and the
compare view want. The pieces concatenate byte for byte — a chunk that is not the last
carries its trailing newline — so a caller never has to know where the separators went.
These are additive parameters in the manner of
[ADR-0055](0055-core-answers-host-questions.md), so no protocol version moves and an older
frontend is unaffected. The channel itself was never slow; the parser was, and the fix is
to stop handing it a pathological input.

**The budget follows the measurement.** Opening an 8 MB file went from about thirteen
seconds to about 1.6, with highlighting on rather than stripped to plain text, and the
curve is linear. The ceiling in ADR-0132 therefore moves from 8 MiB to 64 MiB, which is
where an open now costs roughly what 8 MB used to and is back in territory worth asking
about. Nothing else about that decision changes: it is still a question and not a refusal,
still an additive `force`, still asked at every door, and a forced open still starts as
plain text. The judgement was always about a person's patience; the code got faster, so the
same judgement lands on a different number.

## Alternatives considered

- **Windowed or lazy loading** — keeping the file on disk and rendering only a window of
  lines. It is the one thing that would beat Notepad++ outright, and it is rejected rather
  than deferred. It costs the Tk text widget as the document, and find, marks, selection,
  the `line.col` indices undo is recorded in ([ADR-0012](0012-document-model-lines.md)),
  the gutter and vi's jumps all rest on the widget holding the whole buffer. The
  measurements removed the motivation: the widget is 0.3% of the cost of an open.
- **A bounded back-scan for highlighter state** — begin scanning a few hundred lines above
  the viewport and accept occasional wrong colours. Faster, and sometimes simply wrong: a
  string or comment opened far above would be missed, and the error would be invisible
  until someone scrolled. The prefix scan is made cheap by chunking and yielding instead. A
  test fails for any back-scan implementation, which is the point of that test.
- **Capping the well-formedness pass at a prefix.** Already rejected by ADR-0132 and still
  rejected: declaring a whole file UTF-8 on the strength of its first megabyte makes the
  read lossy for a file that turns invalid later.
- **Accepting the plain round trip without excluding surrogates.** Declined: the round trip
  alone accepts CESU-8, which is lossless but would make "valid UTF-8" a false claim in the
  buffer's metadata and in the manual. The extra test costs about a millisecond per
  megabyte on ordinary text.
- **Replacing tcllib's JSON parser.** Not done. The parser is fine on sane inputs; one
  operation was handing it an insane one. Chunking the payload fixed the cost without
  touching the JSON layer or moving the protocol.

## Consequences

- Large files open several times faster, with highlighting on, and the budget that guards
  them is eight times higher.
- Highlighting cost no longer scales with file size; it scales with the window.
- Jumping straight to the end of a very large file still front-loads a scan proportional to
  the file, because exact multi-line state has no cheaper route to line N. It is
  progressive and does not block, but it is real, and CAVEATS.md carries it.
  Checkpointing would help a repeat jump and never the first.
- Two linear whole-file passes remain, in JSON string escaping and in line-ending counting.
  Both are on ROADMAP.md. The line-ending one sits inside encoding detection, where a wrong
  answer corrupts a file silently, so it wants its own sitting.
- A frontend that asks for a document without a start line still gets it whole, and pays
  the old parse cost for doing so.
- The performance claims here were measured on one machine at one time. They justify the
  shape of the decision, not any particular number a later reader will reproduce.

## Amendment, 2026-09-21: the two remaining passes, and what the frontier scan measured

Both whole-file passes the Consequences left open are gone, and the cost of the frontier
scan was measured instead of reasoned about. Nothing above is decided differently; this is
the same argument with its closing numbers, and two corrections to it.

**Line-ending detection stopped counting.** The normalization that rewrites CRLF to LF
loses exactly one character per pair, so the number of pairs is the length it lost, and
that costs nothing. With that number in hand the common case needs no pass either: no CRLF
means every newline is a bare LF, nothing is mixed, and the convention is settled without
looking at the text. An LF file went from about 15.5 to 0.9 ms/MB, a CRLF one from 22.3 to
10.5. This is the one computation in rio whose wrong answer corrupts a file in silence,
which is why the Consequences said it wanted its own sitting; what the sitting produced is
a differential test holding the new verdict against the counting implementation it
replaced, over adversarial and randomly generated inputs rather than over examples.

**The JSON escape asks before it works.** A `string map` compares every input character
against the first character of every pair, so the full escape map spent twenty-nine of its
thirty-four comparisons on C0 controls that a source document does not contain. One
regular expression now asks whether the value contains any of them. If it does, the
original map runs unchanged; if it does not, a five-pair map runs over a value just proven
to need nothing else. Asking first rather than escaping in two stages is the point: the two
maps never both run, so there is no ordering between them to get wrong, and a value that
does contain a control pays only the question — 56.5 against 56.1 ms/MB, nothing traded for
the win. Ordinary text went from about 56 to 20 ms/MB, and a 256 KB document chunk from
13.9 to 4.9 ms. Both maps are derived from the one original where they are defined, so they
cannot drift apart, and their equivalence is again a differential test.

**The frontier scan is finished.** Its chunk is now fetched from the text widget once and
split, rather than a line at a time, and the recorded entry states are interned, so every
line entering in the same state shares one object. On an 8 MB file the scan went from 22.6
to 20.5 µs a line and the entry-state cache from 36.5 to 8.7 MB. The memory is the real
result: a 4 MB file has two distinct entry states across its 131,072 lines, so sharing them
makes the cache a pointer per line.

The breakdown settles what is left. At about 20 µs a line the scanners themselves are 19.5
of them; the widget fetch was 1.7 and is now 0.1, and the allocation was inside the noise.
Nothing in the loop around the scanners is worth another pass. The only lever remaining is
a per-line predicate inside each scanner, declaring that a line cannot change the entry
state — an addition to [ADR-0032](0032-syntax-highlighting-in-frontend.md)'s scanner
contract across every language rio ships, and one differential test per language to be safe
about it. It was measured and deliberately not built. It is a decision for another day, not
a deferred task with a plan attached.

**Checkpointing is un-planned, not deferred.** The Consequences above say that
checkpointing the scan state every so many lines would help a repeat jump and never the
first. That is wrong. The entry-state cache is a dense prefix that persists, so a second
jump to the same place skips the scan entirely and a repeat jump is already free.
Checkpointing would trade that property away for memory, and interning the entry states
recovers the memory without the trade. The cost of the *first* jump stands as stated, and
remains the price of exact multi-line state.

One change the plan called for was not made: the same bulk fetch in the incremental
repaint's scan-only branch. That pass usually re-converges within a line or two of an edit,
so a chunk-sized fetch would pull a thousand lines to read three — a pessimisation on the
one path that runs on every keystroke.
