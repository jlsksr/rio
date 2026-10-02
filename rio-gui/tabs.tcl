# rio-gui/tabs.tcl — the title, the status bar and each group's tab strip.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# Modified flag, title, status, and the tab bar.
# ---------------------------------------------------------------------------
proc mark_modified {m} {
	if {$::cur eq ""} return
	set was [bufget $::cur modified]
	bufset $::cur modified $m
	if {$m != $was} { refresh_tabs ; refresh_title }
	refresh_status
}
proc clear_modified {} { bufset $::cur modified 0 ; refresh_all }

# A buffer's display name, without the unsaved marker.
proc tab_name {id} {
	set p [bufget $id path]
	return [expr {$p eq "" ? "untitled" : [file tail $p]}]
}
# " ●" for an unsaved buffer, else "" (D27). For the tab and the title.
proc tab_dot {id} {
	return [expr {[bufget $id modified] ? " ●" : ""}]
}
proc refresh_all   {} { refresh_tabs ; refresh_title ; refresh_status }
proc refresh_title {} {
	set suffix [expr {$::core_remote ? " — $::core_endpoint" : ""}]
	wm title . "rio — [tab_name $::cur][tab_dot $::cur]$suffix"
}
proc refresh_status {} {
	set p    [bufget $::cur path]
	set name [expr {$p eq "" ? "untitled" : $p}]
	set meta [bufget $::cur meta]
	set enc  [expr {[dict exists $meta encoding] ? [dict get $meta encoding] : "utf-8"}]
	set eol  [expr {[dict exists $meta eol] ? [dict get $meta eol] : "lf"}]
	set lang [expr {[gget $::focus hl_lang] ne "" ? [gget $::focus hl_lang] : "plain text"}]
	set mode ""   ;# the editing mode's segment (vi's "-- INSERT --"), when it has one
	if {$::editmode_status ne ""} { set mode "      $::editmode_status" }
	.status configure -text [format "%s      %s  %s%s      %s      %s      %d buffer(s)%s" \
		$name $enc $eol [expr {[bufget $::cur modified] ? {      modified} : {}}] \
		$lang [cursor_status] [dict size $::buffers] $mode]
	# The caret may have moved without a key (open, tab switch, reload).
	if {$::focus ne "" && [dict exists $::grp $::focus]} { curline_update $::focus }
}
# The status bar's caret position: "Ln 12, Col 5". Col is 1-based.
proc cursor_status {} {
	if {$::focus eq "" || ![dict exists $::grp $::focus]} { return "" }
	if {[catch {[fgw] index insert} idx]} { return "" }
	lassign [split $idx .] line char
	return [format "Ln %d, Col %d" $line [expr {$char + 1}]]
}
# Put text on the clipboard; nothing for empty text.
proc rio_copy_clip {text} {
	if {$text eq ""} return
	clipboard clear
	clipboard append $text
}
# Copy a tab's file path to the clipboard.
proc tab_copy_path {id} {
	rio_copy_clip [bufget $id path]
}

# Right-click a tab: actions about that tab only (D33). "Move to Other
# Group" creates the other group if there is none.
proc tab_context_menu {g id X Y} {
	catch {destroy .tabmenu}
	menu .tabmenu -tearoff 0
	.tabmenu add command -label "Move to Other Group" -command [list move_buffer_to_other $id $g]
	if {[bufget $id path] ne ""} {
		.tabmenu add command -label "Copy Path" -command [list tab_copy_path $id]
	} else {
		.tabmenu add command -label "Copy Path" -state disabled
	}
	.tabmenu add separator
	.tabmenu add command -label "Close" -command [list close_tab $id $g]
	tk_popup .tabmenu $X $Y
}

# The tab strips (D33): each group draws its own tabs. The focused group's
# active tab has the accent colour.
#
# Dragging a tab:
#   under 5 px             a click: activate
#   onto its own group     reorder, to the slot under the pointer
#   onto the other group   move across
# While dragging, the tab looks pressed, the cursor is a hand, and the other
# group's strip is tinted when the pointer is over it.
proc tab_drag_start {id g X Y} {
	set ::tabdrag [dict create id $id g $g x $X y $Y active 0 tint ""]
}
proc tab_drag_motion {X Y} {
	if {![info exists ::tabdrag]} return
	if {![dict get $::tabdrag active]} {
		if {abs($X - [dict get $::tabdrag x]) < 5 && abs($Y - [dict get $::tabdrag y]) < 5} return
		dict set ::tabdrag active 1
		. configure -cursor hand2
		mark_dragged [dict get $::tabdrag g] [dict get $::tabdrag id]
	}
	set src  [dict get $::tabdrag g]
	set over [group_at $X $Y]
	set want [expr {($over ne "" && $over ne $src) ? $over : ""}]
	set now  [dict get $::tabdrag tint]
	if {$want ne $now} {
		if {$now  ne ""} { tint_strip $now  0 }
		if {$want ne ""} { tint_strip $want 1 }
		dict set ::tabdrag tint $want
	}
}
proc tab_drag_end {id g X Y} {
	if {![info exists ::tabdrag]} { activate $id $g ; return }
	set active [dict get $::tabdrag active]
	set tint   [dict get $::tabdrag tint]
	unset ::tabdrag
	. configure -cursor ""
	if {$tint ne ""} { tint_strip $tint 0 }
	if {!$active} { activate $id $g ; return }   ;# a click, not a drag
	set dst [group_at $X $Y]
	if {$dst eq $g} {
		reorder_tab $g $id $X                    ;# dropped on its own pane -> reorder
	} elseif {$dst ne ""} {
		move_buffer_to_other $id $g              ;# dropped on the other pane -> move across
	}
	refresh_tabs                                 ;# clear the drag mark (no-op if a drop already repainted)
}
# Give the dragged tab a pressed look. refresh_tabs at drag end undoes it.
proc mark_dragged {g id} {
	set w [gget $g tabs].b$id
	if {![winfo exists $w]} return
	set c $::theme_colors
	set a [dict get $c accent] ; set fg [dict get $c tab.active.bg]
	$w configure -relief sunken -background $a
	foreach sub [list $w.l $w.x] { catch {$sub configure -background $a -foreground $fg} }
}
# Highlight (`on`=1) or restore (`on`=0) group `g`'s tab strip as a drop target.
proc tint_strip {g on} {
	set c $::theme_colors
	set bg [expr {$on ? [dict get $c accent] : [dict get $c tab.bar.bg]}]
	catch {[gget $g tabs] configure -background $bg}
}

# Move tab `id` within group `g` to the slot under pointer-x `X`. Only the
# strip repaints.
proc reorder_tab {g id X} {
	set centers [dict create]
	foreach t [gorder $g] {
		set w [gget $g tabs].b$t
		if {[winfo exists $w]} { dict set centers $t [expr {[winfo rootx $w] + [winfo width $w] / 2}] }
	}
	set new [tab_reorder [gorder $g] $id $centers $X]
	if {$new eq [gorder $g]} return              ;# dropped in place
	gset $g order $new
	refresh_tabs
	prefs_save
}
# Move `id` within `order`: its new index is the number of other tabs whose
# centre (`centers`, id -> x) is left of `X`. No geometry, so it can be tested.
proc tab_reorder {order id centers X} {
	set k 0
	foreach t $order {
		if {$t eq $id} continue
		if {[dict exists $centers $t] && $X > [dict get $centers $t]} { incr k }
	}
	return [linsert [lsearch -all -inline -not -exact $order $id] $k $id]
}

proc refresh_tabs {} {
	set c $::theme_colors
	set fg [dict get $c tab.fg]
	foreach g $::groups {
		set strip [gget $g tabs]
		$strip configure -background [dict get $c tab.bar.bg]
		foreach w [winfo children $strip] { destroy $w }
		set focused [expr {$g eq $::focus}]
		foreach id [gorder $g] {
			set active [expr {$id eq [gcur $g]}]
			set bg [expr {$active ? [dict get $c tab.active.bg] : [dict get $c tab.inactive.bg]}]
			set tfg [expr {$active && $focused ? [dict get $c accent] : $fg}]
			set f [frame $strip.b$id -background $bg -borderwidth 1 \
				-relief [expr {$active ? "raised" : "flat"}]]
			label $f.l -text "[tab_name $id][tab_dot $id]" -background $bg -foreground $tfg \
				-font RioUIFont -padx 6 -pady 1
			label $f.x -text "×" -background $bg -foreground $fg \
				-font RioUIFont -padx 3
			# Press, drag, release: a click activates, a drag moves the tab.
			foreach w [list $f $f.l] {
				bind $w <ButtonPress-1>   [list tab_drag_start $id $g %X %Y]
				bind $w <B1-Motion>       [list tab_drag_motion %X %Y]
				bind $w <ButtonRelease-1> [list tab_drag_end $id $g %X %Y]
			}
			bind $f.x <Button-1> [list close_tab $id $g]
			# Right-click anywhere on the handle (frame, label, ×) for the context menu.
			foreach w [list $f $f.l $f.x] {
				bind $w <<ContextMenu>> [list tab_context_menu $g $id %X %Y]
			}
			pack $f.l -side left ; pack $f.x -side right
			# tabstrip_layout places the handle.
		}
		tabstrip_layout $g
	}
}

# ---------------------------------------------------------------------------
# Tab-strip layout (D57). refresh_tabs builds the tab handles; this places
# them, in the mode ::tab_layout:
#
#   scroll   one row; on overflow ◂ ▸ arrows and a window of tabs
#   multi    wrapped onto as many rows as needed
#
# It also runs on the strip's <Configure>. Widths come from `font measure`,
# not from mapped widgets, so the layout works before anything is mapped.
# ---------------------------------------------------------------------------

# The width of tab handle <id>: name and × in RioUIFont, plus 22 px of
# borders and padding (2 + 12 + 6 + 2), as refresh_tabs builds it.
proc tab_pixwidth {id} {
	return [expr {[font measure RioUIFont "[tab_name $id][tab_dot $id]"] \
		+ [font measure RioUIFont "×"] + 22}]
}

# The last tab index that fits when the window starts at `off` and has
# `avail` pixels. The first tab always counts: at least one tab shows.
proc tabstrip_fit_last {ids off avail} {
	set x 0 ; set last $off
	for {set i $off} {$i < [llength $ids]} {incr i} {
		set need [tab_pixwidth [lindex $ids $i]]
		if {$i > $off && $x + $need > $avail} break
		incr x $need ; set last $i
	}
	return $last
}

# Make sure group `g`'s two scroll arrows exist, and colour them.
proc tabstrip_ensure_arrows {strip g} {
	set c $::theme_colors
	foreach {name dir glyph} [list al -1 "◂" ar 1 "▸"] {
		set w $strip.$name
		if {![winfo exists $w]} {
			label $w -text $glyph -font RioUIFont -padx 3 -cursor hand2
			bind $w <Button-1> [list tab_scroll $g $dir]
		}
		catch {$w configure \
			-background [dict get $c tab.bar.bg] -foreground [dict get $c tab.fg]}
	}
}

# One row frame for `multi` mode. Handles are packed into it with -in, which
# does not reparent them: they stay siblings of this frame. It is created
# after them and would cover them, so it is lowered.
proc tabstrip_row {strip row} {
	set w $strip.r$row
	frame $w -background [dict get $::theme_colors tab.bar.bg]
	pack $w -side top -anchor w -fill x
	lower $w
	return $w
}

# Place group `g`'s tab handles. `reveal` moves the scroll window so the
# active tab shows; tab_scroll passes 0, so the arrows can page past it.
proc tabstrip_layout {g {reveal 1}} {
	set strip [gget $g tabs]
	if {$strip eq "" || ![winfo exists $strip]} return
	tabstrip_ensure_arrows $strip $g
	set ids {}
	foreach id [gorder $g] { if {[winfo exists $strip.b$id]} { lappend ids $id } }
	# Unmanage arrows and handles; destroy the row frames of the last pass.
	foreach w [winfo children $strip] {
		if {[string match $strip.r* $w]} { destroy $w ; continue }
		catch {pack forget $w} ; catch {grid forget $w}
	}
	if {[llength $ids] == 0} { gset $g taboff 0 ; return }
	set avail [winfo width $strip]

	if {$::tab_layout eq "multi"} {
		# Pass 1: assign tabs to rows, wrapping before a tab would overrun.
		# Width 1 (not mapped yet): one row; <Configure> lays it out again.
		set A [expr {$avail <= 1 ? 1000000 : $avail}]
		set rows {} ; set cur {} ; set x 0
		foreach id $ids {
			set need [tab_pixwidth $id]
			if {[llength $cur] && $x + $need > $A} { lappend rows $cur ; set cur {} ; set x 0 }
			lappend cur $id ; incr x $need
		}
		if {[llength $cur]} { lappend rows $cur }
		# Pass 2: place them, justified like a paragraph: every row but the
		# last fills the width.
		set nrows [llength $rows]
		for {set r 0} {$r < $nrows} {incr r} {
			set rf [tabstrip_row $strip $r]
			set justify [expr {$r < $nrows - 1}]
			foreach id [lindex $rows $r] {
				if {$justify} {
					pack $strip.b$id -in $rf -side left -padx 1 -pady 1 -expand 1 -fill x
				} else {
					pack $strip.b$id -in $rf -side left -padx 1 -pady 1
				}
			}
		}
		gset $g taboff 0
		return
	}

	# scroll mode: everything on one line.
	set n [llength $ids]
	set total 0 ; foreach id $ids { incr total [tab_pixwidth $id] }
	if {$avail <= 1 || $total <= $avail} {
		# They fit, or nothing is mapped yet: show all, no arrows.
		gset $g taboff 0
		foreach id $ids { pack $strip.b$id -side left -padx 1 -pady 1 }
		return
	}
	# Overflow: reserve room for the two arrows, then show a scrolled window of tabs.
	set aw [expr {[font measure RioUIFont "▸"] + 8}]
	set availtabs [expr {$avail - 2*$aw - 4}]
	if {$availtabs < 1} { set availtabs 1 }
	set off [gget $g taboff]
	if {$off < 0} { set off 0 } elseif {$off > $n - 1} { set off [expr {$n - 1}] }
	if {$reveal} {
		set ai [lsearch -exact $ids [gcur $g]]
		if {$ai >= 0 && $ai < $off} { set off $ai }
		while {$ai >= 0 && $off < $n - 1} {
			if {$ai <= [tabstrip_fit_last $ids $off $availtabs]} break
			incr off
		}
	}
	gset $g taboff $off
	set last [tabstrip_fit_last $ids $off $availtabs]
	pack $strip.al -side left  -padx 1
	pack $strip.ar -side right -padx 1
	for {set i $off} {$i <= $last} {incr i} {
		pack $strip.b[lindex $ids $i] -side left -padx 1 -pady 1
	}
}

# Move group `g`'s tab window by `dir` (-1 left, +1 right): the arrows.
proc tab_scroll {g dir} {
	set n [llength [gorder $g]]
	set off [expr {[gget $g taboff] + $dir}]
	if {$off < 0} { set off 0 } elseif {$off > $n - 1} { set off [expr {$n - 1}] }
	gset $g taboff $off
	tabstrip_layout $g 0
}

# A strip changed size: lay it out again, but only if its width changed.
# multi mode changes the height, and reacting to that would loop.
proc tabstrip_on_configure {g} {
	set strip [gget $g tabs]
	if {$strip eq "" || ![winfo exists $strip]} return
	set w [winfo width $strip]
	if {[dict exists $::tabstrip_w $g] && [dict get $::tabstrip_w $g] == $w} return
	dict set ::tabstrip_w $g $w
	tabstrip_layout $g 1
}

# Apply ::tab_layout: lay out every group's strip, then save.
proc tab_layout_apply {} {
	foreach g $::groups { tabstrip_layout $g }
	prefs_save
}
