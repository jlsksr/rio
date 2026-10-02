# rio-gui/widgets.tcl — small shared widgets: the rich list, tooltips, scrollbars.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# rl_* — a reusable rich-list: a read-only text widget drawn one row per line,
# with full-width hover and selection bands and mouse/keyboard navigation. Both
# the files pane and the git pane (D42/D43) are instances of it — the well chrome,
# the bands, and the nav feel are identical; only the row text and what a row
# *means* differ. State is kept per body widget (arrays keyed by the widget path)
# so the two lists don't share it. Each row carries a `selectable` flag (placeholder
# rows like "(clean)" are not) and an opaque `payload` the owning pane interprets.
#
# The caller renders row text itself (its own glyphs/tags) — the component only
# needs one inserted line per rl_row, in order, so line N maps to row N-1. Two
# callbacks wire behaviour: onselect fires when the selection changes (click or
# arrow), onactivate on double-click / Return; either may be empty. The bands use
# the shared `selrow`/`hoverrow` tags, configured per body in apply_theme.
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
	# <<ContextMenu>>, never <Button-3>: it is Tk's own name for the right mouse button,
	# which is Button-3 on X11 and Windows but Button-2 on macOS (Tk 8.6's numbering
	# there), so a hard-coded Button-3 opens nothing on a Mac (D136). Every right-click
	# menu in rio binds this event.
	bind $b <<ContextMenu>>   "rl_context %W %x %y %X %Y ; break"
	# A read-only list selects one row at a time (Button-1 / Return / arrows). It has
	# no use for the Text widget's own text selection, and -state disabled does not
	# suppress it: a drag, a shift-click or a line/word multi-click still sweeps a
	# stray multi-line highlight over the row model (reported in the files pane).
	# Neutralise every gesture that would begin or extend a text selection — mouse and
	# keyboard — while leaving scrolling and our own navigation untouched.
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
# Begin a repaint: enable, clear text and state. Caller then inserts rows and ends.
proc rl_begin {b} {
	$b configure -state normal
	$b delete 1.0 end
	rl_reset $b
}
# Record one row. The caller has already inserted exactly one line of text for it.
proc rl_row {b selectable payload} {
	lappend ::rl_rows($b) [list $selectable $payload]
}
proc rl_end {b} { $b configure -state disabled }

proc rl_selectable {b i} {
	if {$i < 0 || $i >= [llength $::rl_rows($b)]} { return 0 }
	return [lindex [lindex $::rl_rows($b) $i] 0]
}
proc rl_payload {b i} { return [lindex [lindex $::rl_rows($b) $i] 1] }

# Paint the hover and selection bands. Tagging through the trailing newline (+1c)
# makes a band span the full pane width, not just the text. selrow sits above
# hoverrow (see apply_theme) so the selection stays visible under the pointer.
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

# Select a row by index (ignoring placeholder rows), repaint, scroll it into view,
# and fire onselect. `fire` lets a headless test set a selection without the callback.
proc rl_select {b row {fire 1}} {
	if {![rl_selectable $b $row]} return
	set ::rl_sel($b) $row
	rl_paint $b
	$b see [expr {$row + 1}].0
	if {$fire && $::rl_onselect($b) ne ""} {
		{*}$::rl_onselect($b) [rl_payload $b $row]
	}
}
# Drop the selection: no row is current. A pane needs this when it shows something that
# has no row of its own — the help viewer following a link out of the contents list.
proc rl_clear {b} { set ::rl_sel($b) -1 ; rl_paint $b }

# Double-click / Return: run onactivate on the selected row.
proc rl_activate {b} {
	set row $::rl_sel($b)
	if {![rl_selectable $b $row]} return
	if {$::rl_onactivate($b) ne ""} {
		{*}$::rl_onactivate($b) [rl_payload $b $row]
	}
}
# Right-click: select the row under the pointer (band only — fire=0, so a git-pane
# right-click doesn't also load its diff) and hand its payload + root coords to the
# owning pane's oncontext, which pops a menu. A right-click off any row does nothing.
proc rl_context {b x y X Y} {
	set row [rl_row_at $b $x $y]
	if {![rl_selectable $b $row]} return
	rl_select $b $row 0
	if {$::rl_oncontext($b) ne ""} {
		{*}$::rl_oncontext($b) [rl_payload $b $row] $X $Y
	}
}

# Row index under a pixel: the text line at @x,y, minus one (line N -> row N-1).
proc rl_row_at {b x y} {
	return [expr {[lindex [split [$b index @$x,$y] .] 0] - 1}]
}
proc rl_click {b x y} {
	if {![llength $::rl_rows($b)]} return
	rl_select $b [rl_row_at $b $x $y]
}
# Keyboard move: step the selection by ±1, skipping placeholder rows, clamped.
proc rl_move {b dir} {
	set n [llength $::rl_rows($b)]
	if {$n == 0} return
	set cur $::rl_sel($b)
	if {$cur < 0} { set cur [expr {$dir > 0 ? -1 : $n}] }
	for {set i [expr {$cur + $dir}]} {$i >= 0 && $i < $n} {incr i $dir} {
		if {[rl_selectable $b $i]} { rl_select $b $i ; return }
	}
}
# Hover follows the pointer; -1 clears it. No-op when unchanged so we don't repaint
# on every motion pixel.
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

# An auto-hiding scrollbar: visible only when the view can't show everything.
# Wired as a widget's -yscrollcommand (Tk appends the lo/hi fractions). It re-packs
# with -before the scrolled widget so it reclaims its edge instead of being
# squeezed to zero width by that widget's -expand. Keeps the dock uncluttered
# when a short file list or change list fits — the common case.
proc autoscroll {sb widget lo hi} {
	if {$lo <= 0.0 && $hi >= 1.0} {
		pack forget $sb
	} else {
		pack $sb -side right -fill y -before $widget
	}
	$sb set $lo $hi
}

# Same idea for a grid-managed scrollbar (the editor's horizontal bar). grid remove
# keeps the cell config, so re-`grid`ing restores its row/col. Wired as the editor's
# -xscrollcommand so the bar shows only when a line runs past the right edge.
proc gridscroll {sb lo hi} {
	if {$lo <= 0.0 && $hi >= 1.0} { grid remove $sb } else { grid $sb }
	$sb set $lo $hi
}

# Blend two "#rrggbb" colours: pct% of b mixed into a, returned as "#rrggbb". Used
# to derive theme-relative tints (e.g. the files pane's hover band) without needing
# a dedicated theme role for every shade. winfo rgb resolves names/hex to 16-bit
# channels; we scale back to 8-bit.
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
# Hover tooltips (D63). rio's little header controls are bare glyphs (⟳ refresh, ◉/◌
# hidden toggle, …) with no text label to say what they do; a tooltip names them on hover.
# One shared borderless toplevel (.tt), shown after a short delay below the widget and
# hidden on leave. The classic Windows info-tip look — pale yellow, thin dark border, black
# text — theme-independent momentary chrome (it never has to match the pane behind it).
# `tooltip $w $text` attaches the behaviour; re-calling it just updates the text (so a
# stateful control like the hidden toggle can re-label itself). The text is stashed per
# widget in ::tt_text so an update needs no re-bind churn.
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
	# Sit just below the control's left edge; nudge left if it would run off the screen.
	update idletasks
	set x [winfo rootx $w]
	set y [expr {[winfo rooty $w] + [winfo height $w] + 2}]
	set over [expr {$x + [winfo reqwidth .tt] - [winfo screenwidth .tt]}]
	if {$over > 0} { set x [expr {$x - $over - 4}] }
	wm geometry .tt +$x+$y
	wm deiconify .tt
	raise .tt
}
