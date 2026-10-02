# rio-gui/widgets.tcl — small shared widgets: the rich list, tooltips, scrollbars.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# rl_* — the rich list: a read-only text widget, one row per line, with
# hover and selection bands and mouse and keyboard navigation. The files,
# git and search panes use it (D42, D43). State is per body widget.
#
# The caller paints:
#
#   rl_begin $b
#   $b insert end "(clean)\n" ;  rl_row $b 0 {}         ;# a placeholder
#   $b insert end "a.tcl\n"   ;  rl_row $b 1 $payload   ;# selectable
#   rl_end $b
#
# One inserted line per rl_row, so line N is row N-1. Callbacks, each may
# be "": onselect (click, arrows), onactivate (double-click, Return),
# oncontext (right-click). They get the row's payload.
# ---------------------------------------------------------------------------
proc rl_init {b onselect onactivate oncontext} {
	set ::rl_onselect($b)   $onselect
	set ::rl_onactivate($b) $onactivate
	set ::rl_oncontext($b)  $oncontext
	rl_reset $b
	bind $b <Button-1>        "focus %W ; rl_click %W %x %y ; break"
	bind $b <Double-Button-1> "rl_click %W %x %y ; rl_activate %W ; break"
	bind $b <Return>          "rl_activate %W ; break"
	bind $b <Up>              "rl_move %W -1 ; break"
	bind $b <Down>            "rl_move %W 1 ; break"
	bind $b <Motion>          "rl_hover_at %W %x %y"
	bind $b <Leave>           "rl_set_hover %W -1"
	# <<ContextMenu>>, never <Button-3>: the right button is Button-2 on
	# macOS (D136).
	bind $b <<ContextMenu>>   "rl_context %W %x %y %X %Y ; break"
	# Block the text widget's own selection gestures: -state disabled does
	# not, and a drag would sweep a highlight over the rows.
	foreach seq {<B1-Motion> <Double-B1-Motion> <Triple-B1-Motion> <Shift-B1-Motion>
	             <Shift-Button-1> <Triple-Button-1> <Shift-Up> <Shift-Down>} {
		bind $b $seq break
	}
}
proc rl_reset {b} {
	set ::rl_rows($b)  {}
	set ::rl_sel($b)   -1
	set ::rl_hover($b) -1
}
# Begin a repaint: clear the text and the state.
proc rl_begin {b} {
	$b configure -state normal
	$b delete 1.0 end
	rl_reset $b
}
# Record one row. The caller has inserted its one line of text.
proc rl_row {b selectable payload} {
	lappend ::rl_rows($b) [list $selectable $payload]
}
proc rl_end {b} { $b configure -state disabled }

proc rl_selectable {b i} {
	if {$i < 0 || $i >= [llength $::rl_rows($b)]} { return 0 }
	return [lindex [lindex $::rl_rows($b) $i] 0]
}
proc rl_payload {b i} { return [lindex [lindex $::rl_rows($b) $i] 1] }

# Paint the hover and selection bands. The tag includes the newline, so a
# band spans the pane's width.
proc rl_paint {b} {
	$b tag remove hoverrow 1.0 end
	$b tag remove selrow   1.0 end
	if {$::rl_hover($b) >= 0} {
		set L [expr {$::rl_hover($b) + 1}]
		$b tag add hoverrow $L.0 "$L.0 lineend +1c"
	}
	if {$::rl_sel($b) >= 0} {
		set L [expr {$::rl_sel($b) + 1}]
		$b tag add selrow $L.0 "$L.0 lineend +1c"
	}
}

# Select a row, scroll to it and call onselect. `fire` 0: no callback.
proc rl_select {b row {fire 1}} {
	if {![rl_selectable $b $row]} return
	set ::rl_sel($b) $row
	rl_paint $b
	$b see [expr {$row + 1}].0
	if {$fire && $::rl_onselect($b) ne ""} {
		{*}$::rl_onselect($b) [rl_payload $b $row]
	}
}
# Drop the selection, for a pane showing something that has no row.
proc rl_clear {b} { set ::rl_sel($b) -1 ; rl_paint $b }

# Double-click / Return: run onactivate on the selected row.
proc rl_activate {b} {
	set row $::rl_sel($b)
	if {![rl_selectable $b $row]} return
	if {$::rl_onactivate($b) ne ""} {
		{*}$::rl_onactivate($b) [rl_payload $b $row]
	}
}
# Right-click: select the row under the pointer, without onselect, and call
# oncontext with its payload and the root coordinates.
proc rl_context {b x y X Y} {
	set row [rl_row_at $b $x $y]
	if {![rl_selectable $b $row]} return
	rl_select $b $row 0
	if {$::rl_oncontext($b) ne ""} {
		{*}$::rl_oncontext($b) [rl_payload $b $row] $X $Y
	}
}

# The row index under a pixel.
proc rl_row_at {b x y} {
	return [expr {[lindex [split [$b index @$x,$y] .] 0] - 1}]
}
proc rl_click {b x y} {
	if {![llength $::rl_rows($b)]} return
	rl_select $b [rl_row_at $b $x $y]
}
# Move the selection by ±1, skipping placeholder rows.
proc rl_move {b dir} {
	set n [llength $::rl_rows($b)]
	if {$n == 0} return
	set cur $::rl_sel($b)
	if {$cur < 0} { set cur [expr {$dir > 0 ? -1 : $n}] }
	for {set i [expr {$cur + $dir}]} {$i >= 0 && $i < $n} {incr i $dir} {
		if {[rl_selectable $b $i]} { rl_select $b $i ; return }
	}
}
# Hover follows the pointer; -1 clears it. Repaints only on a change.
proc rl_hover_at {b x y} {
	if {![llength $::rl_rows($b)]} return
	rl_set_hover $b [rl_row_at $b $x $y]
}
proc rl_set_hover {b row} {
	if {$row >= [llength $::rl_rows($b)]} { set row -1 }
	if {$row >= 0 && ![rl_selectable $b $row]} { set row -1 }
	if {$row == $::rl_hover($b)} return
	set ::rl_hover($b) $row
	rl_paint $b
}

# A scrollbar shown only when needed. Use as a -yscrollcommand:
#   -yscrollcommand [list autoscroll $sb $widget]
# Packed -before the widget, or the widget's -expand squeezes it to nothing.
proc autoscroll {sb widget lo hi} {
	if {$lo <= 0.0 && $hi >= 1.0} {
		pack forget $sb
	} else {
		pack $sb -side right -fill y -before $widget
	}
	$sb set $lo $hi
}

# The same for a gridded scrollbar (the editor's horizontal one).
# `grid remove` remembers the cell.
proc gridscroll {sb lo hi} {
	if {$lo <= 0.0 && $hi >= 1.0} { grid remove $sb } else { grid $sb }
	$sb set $lo $hi
}

# Mix pct% of colour b into colour a. Tints without a theme role each.
#   blend_hex #000000 #ffffff 50  ->  #7f7f7f
proc blend_hex {a b pct} {
	lassign [winfo rgb . $a] ar ag ab
	lassign [winfo rgb . $b] br bg bb
	set mix [list]
	foreach x [list $ar $ag $ab] y [list $br $bg $bb] {
		lappend mix [expr {(($x * (100 - $pct) + $y * $pct) / 100) >> 8}]
	}
	return [format "#%02x%02x%02x" {*}$mix]
}

# ---------------------------------------------------------------------------
# Tooltips (D63): they name the glyph buttons (⟳, ◉/◌). One shared
# toplevel (.tt), shown 600 ms after the pointer enters, below the widget.
# Pale yellow, black border: the Windows look, whatever the theme.
#   tooltip $w "Refresh"     attach; call again to change the text
# ---------------------------------------------------------------------------
set ::tt_after ""
proc tooltip {w text} {
	set ::tt_text($w) $text
	bind $w <Enter>      [list tooltip_schedule $w]
	bind $w <Leave>      tooltip_hide
	bind $w <ButtonPress> tooltip_hide   ;# ignored where a more-specific <Button-1> exists; <Leave> covers those
}
proc tooltip_schedule {w} {
	tooltip_cancel
	set ::tt_after [after 600 [list tooltip_show $w]]
}
proc tooltip_cancel {} {
	if {$::tt_after ne ""} { after cancel $::tt_after ; set ::tt_after "" }
}
proc tooltip_hide {} {
	tooltip_cancel
	catch {wm withdraw .tt}
}
proc tooltip_show {w} {
	set ::tt_after ""
	if {![winfo exists $w] || ![info exists ::tt_text($w)]} return
	if {![winfo exists .tt]} {
		toplevel .tt -background black          ;# the 1px border is this bg showing past the label
		wm overrideredirect .tt 1
		wm withdraw .tt
		label .tt.l -background "#ffffe1" -foreground black -font RioUIFont \
			-padx 4 -pady 1 -justify left
		pack .tt.l -padx 1 -pady 1
	}
	.tt.l configure -text $::tt_text($w)
	# Below the widget's left edge; moved left if it would leave the screen.
	update idletasks
	set x [winfo rootx $w]
	set y [expr {[winfo rooty $w] + [winfo height $w] + 2}]
	set over [expr {$x + [winfo reqwidth .tt] - [winfo screenwidth .tt]}]
	if {$over > 0} { set x [expr {$x - $over - 4}] }
	wm geometry .tt +$x+$y
	wm deiconify .tt
	raise .tt
}
