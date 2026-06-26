#!/bin/sh
# run-all.sh — drive the Ck spike probes headlessly via tmux and check the
# rendered screen. Hosts each probe in a detached tmux session (a real pty +
# terminal emulator), reads the screen with `capture-pane`, and greps for the
# probe's sentinels. This automates the parts of O1 that are about *rendering*
# (widgets draw, edits land, layout reflows) on THIS box; the human criteria
# (feel of redraw/latency #6, behaviour across terminals incl. Cygwin #4) are
# not covered here — judge those by running the probes in your own terminal.
#
# Prereq: ../deploy.sh has built ck8.6/cwsh and installed tmux.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
ck="$here/../ck8.6"
cwsh="$ck/cwsh"
lib="$ck/library"
# cwsh is built shared (--enable-shared) and not installed, so libck8.6.so lives
# in the build dir — put it on the runtime search path.
ckenv="LD_LIBRARY_PATH=$ck CK_LIBRARY=$lib"

[ -x "$cwsh" ] || { echo "no $cwsh — run ./deploy.sh first" >&2; exit 1; }
command -v tmux >/dev/null || { echo "tmux not installed — run ./deploy.sh" >&2; exit 1; }

fails=0
W=120 H=40

# start_probe SESSION PROBE  — launch a probe in a detached tmux session.
start_probe() {
	tmux kill-session -t "$1" 2>/dev/null || true
	tmux new-session -d -s "$1" -x "$W" -y "$H" "env $ckenv $cwsh $2"
	sleep 2
}
grab() { tmux capture-pane -t "$1" -p; }
stop_probe() { tmux kill-session -t "$1" 2>/dev/null || true; }

check() { # check LABEL HAYSTACK NEEDLE
	if printf '%s' "$2" | grep -qF "$3"; then
		echo "PASS  $1"
	else
		echo "FAIL  $1  (expected to find: $3)"
		fails=$((fails + 1))
	fi
}

echo "== probe 01: build & run + colour =="
start_probe spike01 "$here/01-build-run.tcl"
cap=$(grab spike01)
check "01 screen rendered"   "$cap" "CK-SPIKE-01 READY"
check "01 status/geometry"   "$cap" "CK-SPIKE-01 OK"
check "01 listbox laid out"  "$cap" "alpha"
stop_probe spike01

echo "== probe 02: editing surface =="
start_probe spike02 "$here/02-edit.tcl"
cap=$(grab spike02)
check "02 buffer rendered"   "$cap" "CK-SPIKE-02"
check "02 line 1 visible"    "$cap" "   1:"
# Exercise an edit: send 'i', then confirm the inserted sentinel appears.
tmux send-keys -t spike02 i
sleep 1
cap=$(grab spike02)
check "02 insert landed"     "$cap" "CK-SPIKE-02 INSERTED"
stop_probe spike02

echo "== probe 03: reflow on resize (SIGWINCH via <Expose>) =="
start_probe spike03 "$here/03-reflow.tcl"
check "03 wide=horizontal"   "$(grab spike03)" "LAYOUT: horizontal"
tmux resize-window -t spike03 -x 45 -y "$H"; sleep 1
check "03 narrow=stacked"    "$(grab spike03)" "LAYOUT: stacked"
stop_probe spike03

echo "== probe 04: keyboard (Ctrl/Alt/Fn/nav delivered in tmux) =="
start_probe spike04 "$here/04-keys.tcl"
tmux send-keys -t spike04 C-x; sleep 0.5; check "04 Ctrl-x" "$(grab spike04)" "KEY: Ctrl-x"
tmux send-keys -t spike04 Up;  sleep 0.5; check "04 nav Up"  "$(grab spike04)" "KEY: Up"
stop_probe spike04
echo "      (NOTE: #4's cross-terminal coverage incl. Cygwin is judged BY HAND.)"

echo "== probe 05: Unicode (BMP: latin1/box/arrows/CJK) =="
start_probe spike05 "$here/05-unicode.tcl"
cap=$(grab spike05)
check "05 box-drawing"       "$cap" "┌─┬─┐"
check "05 wide CJK"          "$cap" "日本語"
check "05 rendered to end"   "$cap" "CK-SPIKE-05 END"
echo "      (NOTE: astral/emoji are lost (BMP-only) — expected; rio needs none.)"
stop_probe spike05

echo "== probe 06: redraw animates (frame counter advances) =="
start_probe spike06 "$here/06-redraw.tcl"
f1=$(grab spike06 | sed -n 's/.*frame=\([0-9]*\).*/\1/p' | tail -1); sleep 1
f2=$(grab spike06 | sed -n 's/.*frame=\([0-9]*\).*/\1/p' | tail -1)
if [ -n "$f1" ] && [ -n "$f2" ] && [ "$f2" -gt "$f1" ]; then
	echo "PASS  06 animates ($f1 -> $f2)"
else
	echo "FAIL  06 animates ($f1 -> $f2)"; fails=$((fails + 1))
fi
echo "      (NOTE: flicker/latency #6 is FELT — judge by hand in your terminal.)"
stop_probe spike06

echo
if [ "$fails" -eq 0 ]; then
	echo "ALL AUTOMATED CHECKS PASSED — now judge the human criteria (#4 terminals, #6 feel) by hand; record in VERDICT.md"
else
	echo "$fails AUTOMATED CHECK(S) FAILED — capture the screen with 'tmux attach' while a probe runs, note the gap in VERDICT.md"
fi
exit "$fails"
