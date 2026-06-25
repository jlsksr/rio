# Spike: the core⟷frontend protocol seam

> **Superseded.** The bet paid off and the real code now exists: `rio-core/` (the
> UI-less core) and `rio-gui/` (a real Tk frontend on top of it, in-process).
> This spike is kept only as the record of what it proved and how cheaply.

**Throwaway.** This is not rio. It exists to de-risk the single most load-bearing
bet in [AGENTS.md](../../AGENTS.md) *before* any real core code is written against
it — the same instinct as the toolchain probes: prove the assumption with ~200
throwaway lines, not after the architecture is built on it.

## What it proves

| Decision | Claim | How this spike shows it |
|---|---|---|
| **D1** | the core is UI-less | `core.tcl` never `package require Tk`; runs on `vwait`/`fileevent`, exits 0 on signal |
| **D2** | transport-independent protocol | a socket is just one transport; `probe.tcl` (headless, no X) and `front.tcl` (Tk) are interchangeable clients |
| **D3** | core owns the canonical document; frontends are views | the document persists across client connect/disconnect; a view **never edits itself** — it sends a request and waits for the core's echo |
| **D11** | wire = JSONL | `{id,op,params}` → `{id,ok,result}`, plus unsolicited `{event,params}` broadcasts, one JSON object per line |
| **D12** | doc = list of lines, `line.col` coords | one edit primitive, `buffer.replace [start,end) text`; coords are Tk text-widget indices so `.t replace` applies a change for free |

It also pins down the **event-loop interplay** that bit us during toolchain
setup: a headless core driven purely by `vwait`, and a Tk frontend where a socket
`fileevent` fires *under* the Tk event loop. `tktest.tcl` asserts that coexistence
automatically.

## Files

- `core.tcl` — the Tk-free core: owns the document, speaks JSONL, broadcasts changes.
- `front.tcl` — the thin Tk view: keystrokes become `buffer.replace` requests; the
  widget mutates **only** when the core echoes a `buffer.changed` event back.
- `probe.tcl` — headless scripted client; the "smoke test" half — runs with no display.
- `tktest.tcl` — automated check that the Tk loop and the socket fileevent coexist.

## Run it

```sh
tclsh core.tcl &           # start the core (port 7711)
wish front.tcl &           # open a view
wish front.tcl &           # open a second view
```

Type in either window. Every edit round-trips through the core and reappears in
**both** windows — because neither view edits itself; they both render the core's
broadcast. That lockstep is D3 + D11 + D12 working together, live.

Headless check (no X needed):

```sh
tclsh core.tcl & sleep 1; tclsh probe.tcl
```

## Findings

- **The seam is sound and cheap.** Localhost round-trip latency is invisible while
  typing; making the view fully non-authoritative (no self-edit, render-on-echo)
  felt natural, not laggy. The D3 "frontends are dumb views" model is comfortable
  to write against.
- **D12's Tk-index choice pays off immediately.** Because protocol coords *are*
  Tk text indices, the GUI's entire apply path is one line: `.t replace $start
  $end $text`. That validates "the GUI view layer maps near-free."
- **One edit primitive is enough.** insert, delete, and span-replace are all
  degenerate `buffer.replace` calls; the core never needed more.
- **Headless discipline holds.** The core is genuinely Tk-free and exits cleanly;
  the Tk-in-tclsh hazards live entirely on the frontend side of the seam.
- **Keep the view dumb with a widget proxy, not key bindings.** Intercepting
  `<Key>` and reading `%A` is a trap: Tk substitutes `%A` *textually*, so a code
  editor's own characters — `[ " \ {` — break the binding script (and a bare
  letter is an invalid bareword inside `expr`). Renaming the widget command and
  proxying `insert`/`delete` instead catches typing, paste, and cut uniformly,
  with the character arriving as a proper Tcl argument. That's the robust way to
  realize "the frontend never edits itself."
- **Index resolution lags the canonical doc by one round-trip.** A pure view
  resolves indices (the `insert` mark, `line.col`) against its *local* widget,
  which trails the core by one echo. Invisible for human typing — each keystroke
  returns to the event loop and the echo applies before the next key — but it
  means a frontend must not fire dependent edits ahead of the core's echoes. A
  property the real core's frontend has to respect (or resolve indices
  optimistically against a local shadow).

## Out of scope (deliberately)

Concurrent/conflicting edits from two windows at once (no OT/CRDT — single-typist
only), undo, large files, encoding/line-ending preservation (D22), real op
namespaces beyond `buffer.*`, and any error recovery. Those belong to the real
core; the spike only had to prove the seam, and it does.
