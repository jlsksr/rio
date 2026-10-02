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

# The bare display name of a buffer — no modified marker. The unsaved-changes
# dot (●, D27) is a rendering concern added by the tab strip and the title only;
# keeping it out of here means the compare picker and the save prompt show a
# clean filename.
proc tab_name {id} {
	set p [bufget $id path]
	return [expr {$p eq "" ? "untitled" : [file tail $p]}]
}
# The ● (U+25CF) unsaved marker, or "" — appended after the name in the tab and
# the window title (D27).
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
	# The focused group's caret may have moved by a route with no KeyRelease (open /
	# tab switch / goto / reload all land here via refresh_all) — re-band it too.
	if {$::focus ne "" && [dict exists $::grp $::focus]} { curline_update $::focus }
}
# The compact cursor-position segment for the status bar: "Ln 12, Col 5" for the
# focused group's insert mark. Tk indexes columns from 0, so Col is char+1 to match
# the 1-based feel VSCode/editors show. Guarded so an early or focus-less call is a
# harmless "" rather than an error.
proc cursor_status {} {
	if {$::focus eq "" || ![dict exists $::grp $::focus]} { return "" }
	if {[catch {[fgw] index insert} idx]} { return "" }
	lassign [split $idx .] line char
	return [format "Ln %d, Col %d" $line [expr {$char + 1}]]
}
# Put text on the clipboard (a no-op for empty text). The one clipboard idiom the
# context menus share.
proc rio_copy_clip {text} {
	if {$text eq ""} return
	clipboard clear
	clipboard append $text
}
# Copy a tab's file path to the clipboard (context menu). A no-op for an untitled
# buffer, which has no path — the menu disables the item in that case.
proc tab_copy_path {id} {
	rio_copy_clip [bufget $id path]
}

# Right-click a tab handle: a context menu of actions ABOUT THIS TAB (id, g) — nothing
# about other tabs or regions (D33; the UI-design bar: a tab's menu stays scoped to
# that tab). Rebuilt on each popup so Copy Path reflects the current state. "Move to
# Other Group" is one label in both states: with one group the move creates the other
# group, so the label still describes what happens — no context-sensitive wording.
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

# The tab strips (D33): each group draws its OWN tabs into its own strip
# (.eg<g>.tabs). A tab's group is where it lives, so clicking it activates that buffer
# IN that group and focuses the group. The focused group's active tab is emphasised
# with the accent colour, so which pane has focus is visible at a glance. Right-click
# a tab for a context menu (move to the other group / close).
# Drag a tab (D33 follow-on) — a second input gesture onto the move/reorder
# paths. Press a tab and drag it: onto the OTHER group's pane it moves across (the same
# path as the context menu's "Move to Other Group"); back onto its OWN pane it reorders,
# dropping into the slot under the pointer. Below a ~5px threshold it stays a plain click
# (activate). Tk's implicit pointer grab keeps motion/release flowing to the origin tab
# while the button is down, so `winfo containing` sees across both panes. Feedback while
# dragging: the held tab gets a pressed accent look (mark_dragged) and the cursor becomes
# a hand, and a cross-group drag also tints the OTHER group's tab strip.
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
# Give the dragged tab a clear "held" look — a pressed (sunken) handle tinted with the
# accent — so an in-group reorder has feedback too (a between-groups drag also tints the
# target strip). One-way styling: the refresh_tabs at drag-end repaints it back to normal.
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

# Reorder tab `id` within its own group `g` to the slot under pointer-x `X`. The new
# index is "how many OTHER tabs have their centre left of X" — drop-where-the-cursor-is.
# `tab_reorder` does the pure list splice (unit-tested: no geometry); this reads the live
# tab centres and applies. Order is a view concern, so only the strip repaints — the
# active buffer and its text are untouched.
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
# Pure splice: move `id` within `order` to the slot implied by `X` against tab `centers`
# (a dict id->centre-x). Insertion index = count of OTHER tabs whose centre is left of X.
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
			# Press/drag/release on the handle body: a plain click activates, a
			# drag past the threshold moves the tab to the group under the pointer.
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
			# The handle FRAME is left unmanaged here — tabstrip_layout decides which
			# tabs are placed, and how (one scrolled row, or wrapped onto many).
		}
		tabstrip_layout $g
	}
}

# ---------------------------------------------------------------------------
# Tab-strip overflow layout (D57). refresh_tabs builds each group's tab
# HANDLES (the b<id> frames) but leaves them unmanaged; this proc places them, in one
# of two modes the user picks (::tab_layout). It also runs on the strip's <Configure>
# so a window resize re-flows the tabs. Widths are measured analytically from the tab
# text (font measure), not from winfo reqwidth, so the layout is correct synchronously
# — before the handles have been mapped — which keeps it testable without an event loop.
# ---------------------------------------------------------------------------

# The on-screen width of tab handle <id>, mirroring refresh_tabs' construction: frame
# border (bd 1 → 2) + the name label (RioUIFont, -padx 6 → +12) + the × label (-padx 3
# → +6) + the tab's own pack -padx 1 (→ +2). Kept in one place so a padding change here
# and in refresh_tabs stay in step.
proc tab_pixwidth {id} {
	return [expr {[font measure RioUIFont "[tab_name $id][tab_dot $id]"] \
		+ [font measure RioUIFont "×"] + 22}]
}

# The last tab index that still fits when the visible window starts at `off` and has
# `avail` pixels. The first tab (at `off`) always counts, so at least one tab shows even
# in a sliver of space — otherwise a very narrow group could strand every tab.
proc tabstrip_fit_last {ids off avail} {
	set x 0 ; set last $off
	for {set i $off} {$i < [llength $ids]} {incr i} {
		set need [tab_pixwidth [lindex $ids $i]]
		if {$i > $off && $x + $need > $avail} break
		incr x $need ; set last $i
	}
	return $last
}

# Create (once) group `g`'s two scroll arrows in its strip and (re)colour them to the
# theme. refresh_tabs destroys the strip's children each pass, so these are recreated
# on demand; a <Configure>-only layout finds the ones the last refresh_tabs left.
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

# Create and pack one row container for `multi` mode, spanning the strip width and themed
# to the bar background. The tab handles pack into it left-to-right (`pack -in`), so each
# row huddles at natural widths; tabstrip_layout destroys these `r<n>` frames each pass.
# `pack -in` places the handles geometrically but does NOT reparent them — they stay
# children of the strip, i.e. SIBLINGS of this frame. This frame is created after them, so
# it would stack on top and its background would paint over the tabs (an empty bar); lower
# it beneath them so the handles show. (Re-lowered every pass, since we recreate it.)
proc tabstrip_row {strip row} {
	set w $strip.r$row
	frame $w -background [dict get $::theme_colors tab.bar.bg]
	pack $w -side top -anchor w -fill x
	lower $w
	return $w
}

# Place group `g`'s tab handles. In `multi` mode they wrap across packed per-row frames; in
# `scroll` mode they sit on one row (pack), and when they overflow the strip's width the
# ◂ ▸ arrows appear and only a window of them is shown. `reveal` (default on) pulls that
# window so the active tab is visible — wanted when the active tab changed, suppressed
# by tab_scroll so the arrows can page PAST the active tab to reach a hidden one.
proc tabstrip_layout {g {reveal 1}} {
	set strip [gget $g tabs]
	if {$strip eq "" || ![winfo exists $strip]} return
	tabstrip_ensure_arrows $strip $g
	set ids {}
	foreach id [gorder $g] { if {[winfo exists $strip.b$id]} { lappend ids $id } }
	# Unmanage the arrows and tab handles (they're rebuilt/re-placed below); DESTROY any
	# leftover row containers from a previous multi-mode pass so a re-flow or a mode switch
	# leaves no empty rows behind. `-in` never reparents, so a tab handle survives its
	# row-frame's destruction (it stays a child of the strip) — see the multi branch.
	foreach w [winfo children $strip] {
		if {[string match $strip.r* $w]} { destroy $w ; continue }
		catch {pack forget $w} ; catch {grid forget $w}
	}
	if {[llength $ids] == 0} { gset $g taboff 0 ; return }
	set avail [winfo width $strip]

	if {$::tab_layout eq "multi"} {
		# Flow the handles into one packed row-frame per visual row. Pass 1 assigns tabs to
		# rows, wrapping BEFORE a tab would overrun `avail` (so a row never clips) and keeping
		# at least one tab per row. Not yet realized (width 1 during boot): one row; the
		# <Configure> that arrives with the real width re-flows it.
		set A [expr {$avail <= 1 ? 1000000 : $avail}]
		set rows {} ; set cur {} ; set x 0
		foreach id $ids {
			set need [tab_pixwidth $id]
			if {[llength $cur] && $x + $need > $A} { lappend rows $cur ; set cur {} ; set x 0 }
			lappend cur $id ; incr x $need
		}
		if {[llength $cur]} { lappend rows $cur }
		# Pass 2 places them, JUSTIFIED like a paragraph: every row but the last expands its
		# tabs to fill the strip width (closing the ragged right gap); the last row stays
		# natural/left-aligned (a justified paragraph's last line isn't stretched). pack
		# divides the leftover pixels equally among a row's tabs, and -fill x grows each.
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
		# Fits (or not realized yet): show them all, no arrows, window reset to the start.
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

# Page the visible tab window of group `g` by `dir` (-1 left, +1 right). Bound to the
# arrows; suppresses reveal so paging can move past the active tab to a hidden one.
proc tab_scroll {g dir} {
	set n [llength [gorder $g]]
	set off [expr {[gget $g taboff] + $dir}]
	if {$off < 0} { set off 0 } elseif {$off > $n - 1} { set off [expr {$n - 1}] }
	gset $g taboff $off
	tabstrip_layout $g 0
}

# A group's strip changed size (window resize, dock drag): re-flow, but only on an
# actual WIDTH change — multi-mode alters the strip's height as rows come and go, and
# reacting to that would loop. reveal keeps the active tab in view after a resize.
proc tabstrip_on_configure {g} {
	set strip [gget $g tabs]
	if {$strip eq "" || ![winfo exists $strip]} return
	set w [winfo width $strip]
	if {[dict exists $::tabstrip_w $g] && [dict get $::tabstrip_w $g] == $w} return
	dict set ::tabstrip_w $g $w
	tabstrip_layout $g 1
}

# The former top-level Tabs menu (a -postcommand cascade listing every open buffer) was
# retired in D74: reaching a buffer by name is now View ▸ Switch to Tab…, which opens the
# bounded buffer-picker dialog (buffer_pick_rows / buffer_pick_dialog, near compare_open).
# A dialog can't outgrow the screen the way that cascade could on X11, and it shows a path
# hint so same-named tabs are distinguishable.

# The View menu's multi-line toggle changed ::tab_layout: re-flow every group and persist.
proc tab_layout_apply {} {
	foreach g $::groups { tabstrip_layout $g }
	prefs_save
}
