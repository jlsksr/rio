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

[ -x "$cwsh" ] || { echo "no $cwsh — run ./deploy.sh first" >&2; exit 1; }
command -v tmux >/dev/null || { echo "tmux not installed — run ./deploy.sh" >&2; exit 1; }

fails=0
W=120 H=40

# start_probe SESSION PROBE  — launch a probe in a detached tmux session.
start_probe() {
	tmux kill-session -t "$1" 2>/dev/null || true
	tmux new-session -d -s "$1" -x "$W" -y "$H" "env CK_LIBRARY=$lib $cwsh $2"
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

echo
if [ "$fails" -eq 0 ]; then
	echo "ALL AUTOMATED CHECKS PASSED — now judge the human criteria (#4 terminals, #6 feel) by hand; record in VERDICT.md"
else
	echo "$fails AUTOMATED CHECK(S) FAILED — capture the screen with 'tmux attach' while a probe runs, note the gap in VERDICT.md"
fi
exit "$fails"
