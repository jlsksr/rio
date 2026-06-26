# O1 Ck spike — verdict

Fill this in by running the probes (`run-all.sh` for the automated checks; by
hand in xterm/tmux/Cygwin for the human ones). When every row is settled, fold
the conclusion into AGENTS.md O1 and delete `spike/` if Ck passes (or invoke the
D2 safety net — reimplement the TUI in another language — if it fails).

Pass bar (from AGENTS.md): editor pane usable for real editing; layout reflows
correctly on resize; no show-stopping redraw bug; keyboard coverage sufficient.

| # | Criterion (AGENTS.md O1 spec)                  | Probe            | How judged        | Status | Notes |
|---|-----------------------------------------------|------------------|-------------------|--------|-------|
| 1 | Build & run; pin version                      | 01-build-run     | deploy.sh + tmux  | ☐      | Ck commit: ______ |
| 2 | `text` widget usable as a code editor + tags  | 02-edit          | tmux + by hand    | ☐      | vs Tk text: ______ |
| 3 | Responsive layout reflows on SIGWINCH (D9)    | 03-reflow (TODO) | tmux resize       | ☐      | |
| 4 | Keyboard incl. Ctrl/Alt/Fn across terminals   | 04-keys (TODO)   | **by hand**       | ☐      | xterm/tmux/Cygwin |
| 5 | UTF-8 renders (note wide/combining)           | 05-unicode (TODO)| tmux + by hand    | ☐      | |
| 6 | Redraw correctness & latency; no flicker      | 06-redraw (TODO) | **by hand**       | ☐      | feel: ______ |

Probes 03–06 are written against a *working* Ck after `deploy.sh` builds it (so
they're validated, not guessed); 01–02 (the two riskiest criteria — does it
build, is the editor surface usable) are ready now.

**Overall verdict:** ☐ PASS  ☐ FAIL → _____________________________________
