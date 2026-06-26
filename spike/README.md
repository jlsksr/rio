# O1 — the Ck spike (THROWAWAY)

This directory is **not rio code**. It is the time-boxed probe that answers
AGENTS.md **O1**: can Ck (the curses Tk) carry rio's TUI before we commit to it?
It exists to produce a written verdict ([VERDICT.md](probes/VERDICT.md)) and can
be deleted once O1 is closed.

## Layout

- `ck8.6/` — upstream Ck checkout + build (vzvca/ck8.6). **Git-ignored**.
  Removable with `rm -rf ck8.6`. (The canonical Ck build lives in
  `../../rio-dev-deploy.sh --with-ck`, which installs it system-wide; this local
  copy is just what the spike was driven against.)
- `probes/` — the probe scripts (one Ck program per O1 criterion), a tmux-driven
  headless runner, and the verdict checklist.

## Running

1. From the repo root: `./rio-dev-deploy.sh --with-ck` (installs build deps and
   builds Ck — needs sudo for package install). The probes below assume a local
   `spike/ck8.6/` build; adjust `LD_LIBRARY_PATH`/`cwsh` paths if you used the
   system install instead.
2. Then either:
   - **By hand, in your terminal** (the real test — you judge redraw/feel):
     `CK_LIBRARY=spike/ck8.6/library spike/ck8.6/cwsh spike/probes/01-build-run.tcl`
     (press `q` to quit each probe.)
   - **Headless via tmux** (automates layout/Unicode/reflow checks on this box):
     `spike/probes/run-all.sh`

## What can and cannot be automated

`run-all.sh` hosts each probe inside tmux (a real pty + terminal emulator) and
reads the rendered screen with `capture-pane`, so it can check that widgets draw,
that text edits land, that Unicode renders, and that a resize reflows the layout —
**on this Debian box**. It **cannot** judge the genuinely human criteria: feel of
redraw/latency (#6) and behaviour across xterm/tmux/**Cygwin** (#4). Those stay
your call at a real terminal; record them in [VERDICT.md](probes/VERDICT.md),
which becomes the O1 verdict folded back into AGENTS.md.
