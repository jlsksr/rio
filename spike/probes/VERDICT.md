# O1 Ck spike — verdict

**Outcome: PASS on Debian/Linux** (automated, via tmux). Ck can carry rio's TUI.
Two criteria still need your eyes at real terminals — #4 across xterm/tmux/Cygwin
and #6 feel/latency — but nothing here is a show-stopper; on the contrary, the
risky parts (editor surface, resize reflow) work.

## Environment pinned

| Component | Version |
|-----------|---------|
| Ck        | vzvca/ck8.6 @ `1a991e3e1af4137c96477b0b21375bd43a914e07` |
| Tcl       | 8.6.16 |
| ncursesw  | 6.5+20250216-2 (Debian) |
| GCC       | 14.2.0 (needed the legacy-C flags in rio-dev-deploy.sh --with-ck) |

## Criteria

| # | Criterion                                     | Judged       | Status | Finding |
|---|-----------------------------------------------|--------------|--------|---------|
| 1 | Build & run; pin version                      | deploy + tmux | PASS  | Builds with GCC-14 legacy flags (`-fcommon`, demote implicit-decl/int errors) + `make CFLAGS=` override (configure ignores env CFLAGS). Shared build → run with `LD_LIBRARY_PATH=spike/ck8.6`. |
| 2 | `text` widget usable as a code editor + tags  | tmux + hand  | PASS  | 5000-line buffer scrolls; working `scrollbar`; typed input edits; `tag configure -foreground` colours. Colour confirmed via SGR codes (red/green/blue/…). |
| 3 | Responsive layout reflows on SIGWINCH (D9)    | tmux resize  | PASS  | **Ck has NO `<Configure>`** (binding it errors). It handles SIGWINCH internally and fires **`<Expose>`**; `winfo width .` updates. Collapse rule works bound to `<Expose>` — **but guard it**: only re-lay-out when width actually changed, else `<Expose>`→repack→`<Expose>` feedback loops and blanks the UI. |
| 4 | Keyboard incl. Ctrl/Alt/Fn across terminals   | tmux + **hand** | **WEAK** | In **tmux** all chords delivered. But on the **real Debian host terminal only `Ctrl-a` was recognized** — most chords (other Ctrl, Alt, Fn) did not reach the app. Cross-terminal keyboard is the real soft spot (terminals/shells swallow chords; Alt needs meta-sends-escape; flow-control eats Ctrl-s/q). Needs deliberate keymap+terminal work; Cygwin untested. |
| 5 | UTF-8 renders (note wide/combining)           | tmux + hand  | PASS  | BMP renders incl. Latin-1, **box-drawing** (pane borders), arrows, and **wide CJK**. Astral/emoji are lost (surrogate escapes shown) — expected for ncursesw; rio needs none. |
| 6 | Redraw correctness & latency; no flicker      | **hand**     | PASS  | Automated: a ~20 fps full-repaint loop animates cleanly. Confirmed good by eye on the Debian host — no flicker. |

## What remains (human, on your boxes)

Run `01`–`06` by hand and settle the two TODO rows:

```
LD_LIBRARY_PATH=spike/ck8.6 CK_LIBRARY=spike/ck8.6/library \
  spike/ck8.6/cwsh spike/probes/04-keys.tcl     # in xterm, tmux, Cygwin
LD_LIBRARY_PATH=spike/ck8.6 CK_LIBRARY=spike/ck8.6/library \
  spike/ck8.6/cwsh spike/probes/06-redraw.tcl   # watch for flicker
```

## Overall verdict

**Ck is viable for rendering, but the keyboard is a real soft spot.** Rendering,
editing, resize-reflow (`<Expose>`, width-guarded), colour and BMP/CJK/box Unicode
all work; redraw feels clean. The catch is **keyboard #4**: only `Ctrl-a` came
through on the bare Debian terminal, so making rio's keymap actually work across
terminals (let alone Cygwin) is non-trivial, deliberate work — not a free ride on
Ck. Build Ck via `rio-dev-deploy.sh --with-ck`.

**Conclusion:** the spike did its job — it proved the *toolkit* can carry a TUI
and surfaced the real cost (cross-terminal keyboard). Per the project decision to
**defer the TUI** (see AGENTS.md O1), this verdict is the durable reference for
whoever resumes it; the D2 safety net (a TUI in another language against the same
protocol) remains the fallback if Ck's keyboard story can't be made good.
