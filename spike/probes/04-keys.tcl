# O1 probe #4 — keyboard coverage (AGENTS.md O1 criterion 4, D5/D23).
#
# rio's keymap needs modifiers (Ctrl/Alt) and function/navigation keys. This
# shows the last recognized chord; the cross-terminal part (xterm vs tmux vs the
# Cygwin console / Windows Terminal) is the HUMAN half of the criterion — run it
# in each terminal you care about and note which chords arrive. Headless, the
# tmux runner can at least confirm Ctrl/Alt/Fn are delivered at all.

message .m -justify center -width 500 \
	-text "CK-SPIKE-04  press chords; last shown below; q to quit"
pack .m -side top -fill x
frame .f -background white
pack .f -fill both -expand yes
message .out -justify left -width 500 -text "KEY: (none)  CK-SPIKE-04"
pack .out -side bottom -fill x

proc showkey {k} { .out configure -text "KEY: $k  CK-SPIKE-04" }

foreach k {a b c x z} { bind . <Control-$k> [list showkey Ctrl-$k] }
foreach k {a b r g}   { bind . <Alt-$k>     [list showkey Alt-$k]  }
foreach k {F1 F2 F5 F10} { bind . <Key-$k>  [list showkey $k] }
foreach k {Up Down Left Right Home End Prior Next} { bind . <Key-$k> [list showkey $k] }

bind . <Key-q> {exit 0}
focus .
