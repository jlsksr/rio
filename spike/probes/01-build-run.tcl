# O1 probe #1 — build & run + colour (AGENTS.md O1 criterion 1, part of 2).
#
# Proves cwsh starts a curses screen, geometry managers place widgets, and at
# least background colour works (rio's theming maps colour roles onto the
# terminal palette — D24). Stays within Ck's demo-proven API: no `wm` (single
# screen), no `label` (Ck has none — use `message`), `message` takes -justify.
# Colour is set on `frame -background` (proven in Ck's alt.tcl demo).
#
# Run:  CK_LIBRARY=../ck8.6/library ../ck8.6/cwsh 01-build-run.tcl   (q to quit)
# The CK-SPIKE-01 sentinels let the tmux runner confirm the screen rendered.

message .title -justify center -width 200 -text "CK-SPIKE-01 READY  — press q to quit"
pack .title -side top -fill x

# A row of colour swatches: if colour works each frame shows a distinct bg.
frame .row
pack .row -side top -fill x
foreach col {red green blue yellow white} {
	frame .row.$col -width 12 -height 1 -background $col
	pack .row.$col -side left -padx 1
}

# A second widget class (listbox) + a button, to confirm mixed classes lay out.
listbox .lb -height 5
foreach item {alpha beta gamma delta epsilon} { .lb insert end $item }
pack .lb -side left -fill y

button .b -text "OK(q)" -command {exit 0}
pack .b -side left -padx 2

# Status line carries a second sentinel + the screen size Ck reports.
set sz "?x?"
catch {set sz "[winfo screenwidth .]x[winfo screenheight .]"}
message .status -justify left -width 200 -text "screen $sz  CK-SPIKE-01 OK"
pack .status -side bottom -fill x

bind . <Key-q> {exit 0}
focus .
