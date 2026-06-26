# O1 probe #3 — responsive layout reflow on resize (AGENTS.md O1 criterion 3, D9).
#
# THE core UX risk: when the terminal resizes (SIGWINCH), can we react and
# re-lay-out panes side-by-side -> stacked? FINDING: Ck has NO <Configure> event
# (binding it errors); it handles SIGWINCH internally and fires <Expose> on the
# main window, and `winfo width .` reflects the new size. So the D9 collapse rule
# hooks <Expose>. rio's rule is a shared pure function; this only proves Ck can
# *drive* it. The status line names the current layout + width so the tmux runner
# (which resizes the window) can confirm the switch.
#
# Run by hand: resize your terminal narrow/wide and watch the bottom line.

message .info -justify center -width 500 \
	-text "CK-SPIKE-03  resize the terminal narrow<->wide; q to quit"
pack .info -side top -fill x

frame .a -background red
frame .b -background blue
message .status -justify left -width 500 -text "LAYOUT: (pending)"
pack .status -side bottom -fill x

# Guard: <Expose> fires repeatedly, and repacking inside the handler triggers a
# repaint -> another <Expose> -> repack ... feedback loop that blanks the UI. So
# only re-lay-out when the width actually CHANGED. (Finding for the D9 frontend.)
set ::lastw -1
proc relayout {} {
	set w [winfo width .]
	if {$w == $::lastw} return
	set ::lastw $w
	catch {pack forget .a .b}
	if {$w < 60} {
		pack .a -side top -fill both -expand yes
		pack .b -side top -fill both -expand yes
		.status configure -text "LAYOUT: stacked  w=$w  CK-SPIKE-03"
	} else {
		pack .a -side left -fill both -expand yes
		pack .b -side left -fill both -expand yes
		.status configure -text "LAYOUT: horizontal  w=$w  CK-SPIKE-03"
	}
}

# React to the resize via <Expose> (Ck's SIGWINCH-driven event), and lay out now.
bind . <Expose> {relayout}
after 100 relayout
bind . <Key-q> {exit 0}
focus .
