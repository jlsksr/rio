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
| GCC       | 14.2.0 (needed the legacy-C flags in deploy.sh) |

## Criteria

| # | Criterion                                     | Judged       | Status | Finding |
|---|-----------------------------------------------|--------------|--------|---------|
| 1 | Build & run; pin version                      | deploy + tmux | PASS  | Builds with GCC-14 legacy flags (`-fcommon`, demote implicit-decl/int errors) + `make CFLAGS=` override (configure ignores env CFLAGS). Shared build → run with `LD_LIBRARY_PATH=spike/ck8.6`. |
| 2 | `text` widget usable as a code editor + tags  | tmux + hand  | PASS  | 5000-line buffer scrolls; working `scrollbar`; typed input edits; `tag configure -foreground` colours. Colour confirmed via SGR codes (red/green/blue/…). |
| 3 | Responsive layout reflows on SIGWINCH (D9)    | tmux resize  | PASS  | **Ck has NO `<Configure>`** (binding it errors). It handles SIGWINCH internally and fires **`<Expose>`**; `winfo width .` updates. Collapse rule works bound to `<Expose>` — **but guard it**: only re-lay-out when width actually changed, else `<Expose>`→repack→`<Expose>` feedback loops and blanks the UI. |
| 4 | Keyboard incl. Ctrl/Alt/Fn across terminals   | tmux + **hand** | PARTIAL | In tmux: `Control-x`, `Alt-r`, `F1..F10`, arrows/Home/End/PgUp/PgDn all bind and deliver. **TODO (human):** confirm chords arrive in xterm, tmux, and the Cygwin console / Windows Terminal. |
| 5 | UTF-8 renders (note wide/combining)           | tmux + hand  | PASS  | BMP renders incl. Latin-1, **box-drawing** (pane borders), arrows, and **wide CJK**. Astral/emoji are lost (surrogate escapes shown) — expected for ncursesw; rio needs none. |
| 6 | Redraw correctness & latency; no flicker      | **hand**     | TODO  | Automated: a ~20 fps full-repaint loop animates cleanly, no crash. **Feel/flicker/latency must be judged by eye** — run `06-redraw.tcl` in your terminals. |

## What remains (human, on your boxes)

Run `01`–`06` by hand and settle the two TODO rows:

```
LD_LIBRARY_PATH=spike/ck8.6 CK_LIBRARY=spike/ck8.6/library \
  spike/ck8.6/cwsh spike/probes/04-keys.tcl     # in xterm, tmux, Cygwin
LD_LIBRARY_PATH=spike/ck8.6 CK_LIBRARY=spike/ck8.6/library \
  spike/ck8.6/cwsh spike/probes/06-redraw.tcl   # watch for flicker
```

## Overall verdict

☑ **PASS (Linux/Debian)** — Ck is viable; build it per `deploy.sh`, drive resize
via `<Expose>` (width-guarded), accept BMP-only Unicode. Remaining: confirm
keyboard #4 and feel #6 across your terminals incl. Cygwin. If those hold, close
O1 as PASS and fold the build recipe into the real TUI plan; only invoke the D2
safety net (reimplement the TUI in another language) if Cygwin keyboard/redraw
proves unworkable.
