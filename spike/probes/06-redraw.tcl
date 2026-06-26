# O1 probe #6 — redraw correctness & latency (AGENTS.md O1 criterion 6).
#
# This is the most HUMAN criterion: flicker and input latency are felt, not
# grepped. The probe forces a full-screen repaint ~20x/sec (clear + refill a text
# widget). Watch in your terminal for flicker, tearing, or lag; note the feel in
# VERDICT.md. Headless, the runner can only confirm it animates (the frame
# counter advances) and doesn't crash.

message .m -justify center -width 500 \
	-text "CK-SPIKE-06  full repaints ~20/s — watch for flicker; q to quit"
pack .m -side top -fill x
text .t -wrap none
pack .t -fill both -expand yes

set ::n 0
proc tick {} {
	incr ::n
	.t delete 1.0 end
	set bar [string repeat = [expr {$::n % 50}]]
	for {set i 1} {$i <= 18} {incr i} {
		.t insert end [format "line %2d  frame %5d  %s\n" $i $::n $bar]
	}
	.t insert end "CK-SPIKE-06 frame=$::n\n"
	after 50 tick
}
tick

bind . <Key-q> {exit 0}
focus .
