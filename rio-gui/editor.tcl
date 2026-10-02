# rio-gui/editor.tcl — the editor widget: groups, the edit proxy, gutter, wrap, indent, columns.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# Apply ::wrap_lines to every group (View menu). Wrap on: fold at the word,
# no horizontal scrollbar. Wrap off: the bar shows when a line overflows.
proc apply_wrap {} {
	set mode [expr {$::wrap_lines ? "word" : "none"}]
	foreach g $::groups {
		set t [gw $g] ; set hsb [gget $g frame].hsb
		$t configure -wrap $mode
		if {$::wrap_lines} {
			grid remove $hsb
		} else {
			gridscroll $hsb {*}[$t xview]   ;# show only if a line overflows
		}
	}
	cmp_apply_wrap
	prefs_save
}

# The compare panes follow the same setting: they have no horizontal scrollbar.
proc cmp_apply_wrap {} {
	set w [expr {$::wrap_lines ? "word" : "none"}]
	.cmp.l.t configure -wrap $w
	.cmp.r.t configure -wrap $w
}

# ---------------------------------------------------------------------------
# The line-number gutter (View ▸ Line Numbers): a canvas left of each editor
# group, one number per logical line, placed by the text widget's dlineinfo.
# A wrapped line's number is at its first display row.
# Repainted on a scroll, a resize, an edit and a tab switch, in one idle pass.
# Display only: the numbers are never in the buffer (D12).
# ---------------------------------------------------------------------------

# The editor's -yscrollcommand: set the scrollbar, repaint the gutter.
proc edscroll {g lo hi} {
	[gget $g frame].vsb set $lo $hi
	gutter_mark $g
	hl_vmark $g     ;# the window moved — highlight whatever just came into view (D126)
}

# Coalesce a group's gutter repaints into a single idle callback.
proc gutter_mark {g} {
	after cancel [list gutter_redraw $g]
	after idle   [list gutter_redraw $g]
}

# The editor was resized, re-wrapped or zoomed: gutter and highlighting
# depend on the visible lines.
proc editor_reconfigured {g} {
	gutter_mark $g
	hl_vmark $g
}

# The number shown for line `ln` with the caret on line `caret`. Relative
# (vim's hybrid): the distance from the caret; the caret line keeps its own.
#   caret 10:   8 -> 2    10 -> 10    13 -> 3
# No Tk, so it can be tested.
proc gutter_label {ln caret relative} {
	return [expr {$relative && $ln != $caret ? abs($ln - $caret) : $ln}]
}

# Repaint group g's gutter for its visible lines. The width follows the last
# line's digit count (at least two) and is set even unmapped. The numbers
# need a mapped canvas: dlineinfo needs real geometry.
proc gutter_redraw {g} {
	if {!$::line_numbers} return
	if {![dict exists $::grp $g]} return
	set gut [gget $g frame].gutter
	if {![winfo exists $gut]} return
	set t [gw $g]                 ;# the renamed widget COMMAND (::real$g) — subcommands only
	set win [gget $g path]        ;# its window PATH (.eg$g.t) — what winfo takes
	set last [expr {int([$t index end-1c])}]
	set digits [expr {max(2, [string length $last])}]
	set w [expr {$digits * [font measure RioEditorFont 0] + 12}]
	if {[$gut cget -width] != $w} { $gut configure -width $w }
	$gut delete all
	if {![winfo ismapped $gut]} return
	set fg [dict get $::theme_colors gutter.fg]
	set top [expr {int([$t index @0,0])}]
	set bot [expr {int([$t index @0,[winfo height $win]])}]
	if {$bot > $last} { set bot $last }
	set caret [expr {int([$t index insert])}]   ;# anchor for relative numbering
	for {set ln $top} {$ln <= $bot} {incr ln} {
		set dl [$t dlineinfo $ln.0]
		if {$dl eq ""} continue
		set y [expr {[lindex $dl 1] + [lindex $dl 3] / 2}]
		$gut create text [expr {$w - 6}] $y -anchor e -fill $fg -font RioEditorFont \
			-text [gutter_label $ln $caret $::relative_line_numbers]
	}
}

# Apply ::line_numbers: show or hide every group's gutter, then save.
proc apply_line_numbers {} {
	foreach g $::groups {
		set gut [gget $g frame].gutter
		if {$::line_numbers} {
			grid $gut
			gutter_redraw $g
		} else {
			grid remove $gut
		}
	}
	prefs_save
}

# Click a gutter number to select its line; drag to extend line by line
# (D61). A canvas y maps to a line through `index @0,$y`: gutter and text
# share their vertical extent. `lineend +1c` takes the newline, so the whole
# width is selected. The gutter takes no focus, so focus goes to the text.
proc gutter_press {g y} {
	if {![dict exists $::grp $g]} return
	focus_group $g
	focus [gget $g path]
	set ln [expr {int([[gw $g] index @0,$y])}]
	set ::gutter_anchor $ln            ;# scalar — only one drag at a time
	gutter_select $g $ln $ln
}
proc gutter_motion {g y} {
	if {![dict exists $::grp $g] || ![info exists ::gutter_anchor]} return
	gutter_select $g $::gutter_anchor [expr {int([[gw $g] index @0,$y])}]
}
proc gutter_select {g a b} {
	if {$a > $b} { lassign [list $b $a] a b }
	set t [gw $g]
	$t tag remove sel 1.0 end
	$t tag add sel $a.0 "$b.0 lineend +1c"
	$t mark set insert "$b.0 lineend +1c"
	$t see insert
	cursor_moved $g
}

# ---------------------------------------------------------------------------
# The current-line band (View ▸ Highlight Current Line): a full-width
# background on the caret's logical line, per editor group. A `curline` tag,
# under the selection and find tags. `lineend +1c` takes the newline, so the
# band spans the width. Updated wherever the caret moves.
# ---------------------------------------------------------------------------

# Move group g's band to its caret, or clear it when the feature is off.
proc curline_update {g} {
	if {![dict exists $::grp $g]} return
	set t [gw $g]
	if {$::relative_line_numbers} { gutter_mark $g }  ;# relative numbers follow the caret
	$t tag remove curline 1.0 end
	if {!$::highlight_current_line} return
	$t tag add curline "insert linestart" "insert lineend +1c"
}

# View-menu toggle: re-band (or clear) every group, then persist.
proc apply_curline {} {
	foreach g $::groups { curline_update $g }
	prefs_save
}

# View-menu toggle: repaint every gutter, then save. The gutter's width does
# not change.
proc apply_relnum {} {
	foreach g $::groups { gutter_redraw $g }
	prefs_save
}

# ---------------------------------------------------------------------------
# Wrap indent (View ▸ Indent Wrapped Lines). A wrapped line's continuation
# rows are indented to the line's own first non-blank character:
#
#   on:      if {$x} { a long line       off:     if {$x} { a long line
#            that wraps here }                that wraps here }
#
# Display only: a `wrapind:<cols>` tag per line with -lmargin2. Tags move
# with the text, so an edit recomputes only the lines it touched.
# ---------------------------------------------------------------------------

# Visual column of a line's first non-whitespace char, tabs expanded to the
# widget's default 8-column stops (make_editor_group sets no -tabs).
proc wrapind_cols {line} {
	set col 0
	foreach ch [split $line ""] {
		if {$ch eq " "}  { incr col ; continue }
		if {$ch eq "\t"} { set col [expr {($col / 8 + 1) * 8}] ; continue }
		break
	}
	return $col
}

# Pixels per column of the editor font, which is monospace.
proc wrapind_colpx {} { return [font measure RioEditorFont "0"] }

# The wrapind:<cols> tags currently defined on widget t.
proc wrapind_tags {t} {
	set out {}
	foreach tag [$t tag names] { if {[string match wrapind:* $tag]} { lappend out $tag } }
	return $out
}

# Recompute the wrap indent for lines L1..L2 of t. One shared tag per column
# count, made on demand.
proc wrapind_apply {t L1 L2} {
	if {$L2 < $L1} return
	set tags [wrapind_tags $t]
	for {set L $L1} {$L <= $L2} {incr L} {
		foreach tag $tags { $t tag remove $tag $L.0 "$L.0 lineend" }
		if {!$::wrap_indent} continue
		set cols [wrapind_cols [$t get $L.0 "$L.0 lineend"]]
		if {$cols == 0} continue
		set tag wrapind:$cols
		$t tag configure $tag -lmargin2 [expr {$cols * [wrapind_colpx]}]
		$t tag add $tag $L.0 "$L.0 lineend"
	}
}

# Whole-buffer refresh for group g (on open/switch and the menu toggle).
proc wrapind_group {g} {
	if {![winfo exists [gget $g path]]} return
	set t [gw $g]
	wrapind_apply $t 1 [hl_linecount $t]
}

# Reconfigure existing wrapind tags after a font change (pixels-per-column moved).
proc wrapind_refont {t} {
	set px [wrapind_colpx]
	foreach tag [wrapind_tags $t] {
		$t tag configure $tag -lmargin2 [expr {[lindex [split $tag :] 1] * $px}]
	}
}

# View-menu toggle: re-tag every group, then persist (prefs_save self-gates on boot).
proc apply_wrap_indent {} {
	foreach g $::groups { wrapind_group $g }
	prefs_save
}

# Recolour every site's tab strip for the theme. Safe before the sites exist.
proc restyle_tabs {} {
	foreach s {left right bottom} {
		if {[winfo exists .site$s.tabs]} { render_tabs $s }
	}
}

# ---------------------------------------------------------------------------
# Editor split (D33): at most two groups, with ids 0 and 1. A buffer is in
# exactly one group.
# ---------------------------------------------------------------------------
# The other group, or "" if `g` is the only one.
proc other_group {g} {
	foreach o $::groups { if {$o ne $g} { return $o } }
	return ""
}

# The group whose frame (.eg<g>) holds widget `w`, or "". group_at does the
# same from screen coordinates, for drag-and-drop.
proc group_of_widget {w} {
	while {$w ne ""} {
		foreach g $::groups { if {$w eq [gget $g frame]} { return $g } }
		set w [winfo parent $w]
	}
	return ""
}
proc group_at {X Y} { group_of_widget [winfo containing $X $Y] }

# Destroy group `g`'s widgets and remove it from ::grp. The proxy at .eg<g>.t
# is a plain proc and must be removed too, or the slot cannot be rebuilt.
proc destroy_editor_group {g} {
	set path [gget $g path] ; set w [gw $g]
	set ::tabstrip_w [dict remove $::tabstrip_w $g]  ;# forget the strip's cached width (D57)
	catch {destroy [gget $g frame]}
	catch {rename $path ""}
	catch {rename $w ""}
	dict unset ::grp $g
}

# Create an empty second group in the free slot. Returns its id.
proc add_group {} {
	set g [expr {[lsearch -exact $::groups 0] < 0 ? 0 : 1}]
	make_editor_group $g
	lappend ::groups $g
	relayout_groups
	restyle_group $g
	apply_wrap          ;# sync the new group's wrap mode + horizontal scrollbar
	apply_line_numbers  ;# sync the new group's gutter to ::line_numbers
	# Re-attach the mode (idempotent, D38) so it sets up its per-group state,
	# e.g. vi's cursor shape.
	if {$::editmode_active ne ""} { catch {rio::modes::attach $::editmode_active RioMode} }
	after idle even_split   ;# a new split opens 50/50; later user sash drags are kept
	return $g
}

# Fold group `g` into the other one: its tabs move over, its widgets go, the
# other group gets the focus. Not for the only group.
proc collapse_group {g} {
	set o [other_group $g]
	if {$o eq ""} return
	foreach id [gorder $g] { gset $o order [linsert [gorder $o] end $id] }
	set ::groups [lsearch -all -inline -not -exact $::groups $g]
	destroy_editor_group $g
	relayout_groups
	set ::focus $o
	set ::cur [gcur $o]
	refresh_all
}

# Split the editor: a second group with a new empty buffer, focused.
proc split_editor {} {
	if {[llength $::groups] >= 2} return
	set g [add_group]
	set res [rio_result buffer.new {}]
	if {$res eq ""} { collapse_group $g ; return }
	register_buffer [dict get $res buffer] "" {} $g
	activate [dict get $res buffer] $g
	prefs_save
}

# Unsplit: fold the second group back into the first.
proc unsplit_editor {} {
	if {[llength $::groups] < 2} return
	collapse_group [lindex $::groups end]
	prefs_save
}

# View ▸ Split / Unsplit toggle (Ctrl+\).
proc toggle_split {} {
	if {[llength $::groups] >= 2} { unsplit_editor } else { split_editor }
}

# Move buffer `id` from group `src` to the other group, splitting if needed,
# and focus it there. If `src` is left empty it is destroyed. `id` need not
# be src's active tab.
proc move_buffer_to_other {id src} {
	if {[lsearch -exact [gorder $src] $id] < 0} return
	if {[llength $::groups] < 2} { add_group }
	set dst [other_group $src]
	gset $src order [lsearch -all -inline -not -exact [gorder $src] $id]
	gset $dst order [linsert [gorder $dst] end $id]
	if {![llength [gorder $src]]} {
		set ::groups [lsearch -all -inline -not -exact $::groups $src]
		destroy_editor_group $src
		relayout_groups
	} elseif {[gcur $src] eq $id} {
		# the moved buffer was src's active tab — pick a new active for src
		gset $src cur [lindex [gorder $src] 0]
		load_buffer $src
	}
	activate $id $dst
	prefs_save
}

# View ▸ Move Tab to Other Group (Ctrl+]): move the focused group's active buffer.
proc move_tab_other {} {
	if {[gcur $::focus] ne ""} { move_buffer_to_other [gcur $::focus] $::focus }
}

# A one-shot undo break (D90). The core merges typed characters into one undo
# step, which is wrong for a repeated command such as vi's `x`. A mode arms
# this before a discrete command; the next edit starts its own step.
set ::undo_break 0
proc undo_break {} { set ::undo_break 1 }

# The coalesce flag for the edit being sent now, consuming any armed break.
proc undo_coalesce {} {
	if {!$::undo_break} { return 1 }
	set ::undo_break 0
	return 0
}

# The edit proxy, one per text widget. insert, delete and replace become a
# buffer.replace on this group's active buffer; the widget itself changes
# only when the core's event comes back. Any other subcommand goes to the
# real widget.
proc editor_proxy {g args} {
	set rc [gw $g]
	switch -- [lindex $args 0] {
		insert {
			# .t insert <index> <chars> ?tagList chars ...?
			set idx   [$rc index [lindex $args 1]]
			set chars [lindex $args 2]
			if {$chars ne ""} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer [gcur $g] start $idx end $idx text $chars \
						coalesce [undo_coalesce]]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		delete {
			# .t delete <index1> ?index2?
			# No expr on an index: it would turn "1.10" into the float 1.1.
			set i1 [$rc index [lindex $args 1]]
			if {[llength $args] >= 3} {
				set i2 [$rc index [lindex $args 2]]
			} else {
				set i2 [$rc index "[lindex $args 1]+1c"]
			}
			if {[$rc compare $i1 < $i2]} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer [gcur $g] start $i1 end $i2 text {} \
						coalesce [undo_coalesce]]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		replace {
			# .t replace <index1> <index2> <chars>: one edit, one undo step.
			set i1    [$rc index [lindex $args 1]]
			set i2    [$rc index [lindex $args 2]]
			set chars [lindex $args 3]
			if {[$rc compare $i1 < $i2] || $chars ne ""} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer [gcur $g] start $i1 end $i2 text $chars \
						coalesce [undo_coalesce]]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		default { return [$rc {*}$args] }
	}
}

# ---------------------------------------------------------------------------
# Clipboard actions on an editor widget (D38): one implementation for the
# Edit menu and for an editing mode's keys. `w` is a group's proxy path, so
# edits reach the core. Paste replaces the selection, as one undo step.
# ---------------------------------------------------------------------------
proc editor_select_all {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	$w tag remove sel 1.0 end
	$w tag add sel 1.0 "end -1c"
}

proc editor_copy {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	if {[llength [$w tag ranges sel]] == 0} return
	clipboard clear
	clipboard append [$w get sel.first sel.last]
}

proc editor_cut {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	if {[llength [$w tag ranges sel]] == 0} return
	clipboard clear
	clipboard append [$w get sel.first sel.last]
	$w delete sel.first sel.last
}

proc editor_paste {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	if {[catch {clipboard get} txt] || $txt eq ""} return
	if {[llength [$w tag ranges sel]] > 0} {
		$w replace sel.first sel.last $txt
	} else {
		$w insert insert $txt
	}
	$w see insert
}

# ---------------------------------------------------------------------------
# Block indent and dedent (D38); the Windows mode binds Tab and Shift+Tab.
#   Tab, selection          every selected line gets a tab in front
#   Tab, no selection       a tab at the caret
#   Shift+Tab               one level off the selected lines, or the caret's
# One core edit, so one undo step. The block stays selected afterwards.
# ---------------------------------------------------------------------------
proc editor_indent {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	if {[llength [$w tag ranges sel]] == 0} { $w insert insert \t ; $w see insert ; return }
	editor_shift_lines $w 1
}
proc editor_dedent {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	editor_shift_lines $w -1
}

# Shift the selected lines, or the caret's line, by one level: dir 1 adds a
# tab, dir -1 removes a level. A selection ending at column 0 leaves that
# last line out.
proc editor_shift_lines {w dir} {
	set had_sel [expr {[llength [$w tag ranges sel]] > 0}]
	if {$had_sel} {
		set l1 [lindex [split [$w index sel.first] .] 0]
		set le [split [$w index sel.last] .]
		set l2 [lindex $le 0]
		if {$l2 > $l1 && [lindex $le 1] == 0} { incr l2 -1 }
	} else {
		set caret [split [$w index insert] .]
		set l1 [lindex $caret 0] ; set l2 $l1 ; set caretcol [lindex $caret 1]
	}
	set start $l1.0
	set end   [$w index "$l2.0 lineend"]
	set out {} ; set changed 0 ; set removedfirst 0 ; set i 0
	foreach ln [split [$w get $start $end] \n] {
		if {$dir > 0} {
			# Don't grow a wholly blank line into trailing whitespace.
			if {$ln eq ""} { lappend out $ln } else { lappend out "\t$ln" ; set changed 1 }
		} else {
			set s [editor_dedent_one $ln]
			if {$i == 0} { set removedfirst [expr {[string length $ln] - [string length $s]}] }
			if {$s ne $ln} { set changed 1 }
			lappend out $s
		}
		incr i
	}
	if {!$changed} return
	$w replace $start $end [join $out \n]
	if {$had_sel} {
		$w tag remove sel 1.0 end
		$w tag add sel $l1.0 [$w index "$l2.0 lineend"]
		$w mark set insert [$w index "$l2.0 lineend"]
	} else {
		# Keep the caret over the same character.
		set col [expr {$caretcol - $removedfirst}] ; if {$col < 0} { set col 0 }
		$w mark set insert $l1.$col
	}
	$w see insert
}

# One indent level off a line's front: a leading tab, else up to 4 spaces.
proc editor_dedent_one {ln} {
	if {[string index $ln 0] eq "\t"} { return [string range $ln 1 end] }
	set n 0
	while {$n < 4 && [string index $ln $n] eq " "} { incr n }
	return [string range $ln $n end]
}

# ---------------------------------------------------------------------------
# Column editing (D40). Ctrl+Shift+drag makes a cursor that spans lines.
# Alt+drag is taken by X11 window managers.
#
#   zero width   a caret column: typing, Backspace, Delete and Tab act at
#                that column on every spanned line
#   with width   a rectangle: typing overwrites it on every line
#
# - Off by default (::col_on), a Settings toggle. Windows mode only.
# - GUI-side. One operation is one buffer.replace over L1.0..L2.lineend, so
#   one undo step.
# - Columns are character columns: a tab inside the band misaligns it.
# ---------------------------------------------------------------------------

# Is a live column selection on THIS widget? (Guards every key/edit handler.)
proc col_here {w} { return [expr {$::col_active && $w eq $::col_w}] }

# Character length of line L in widget w.
proc col_linelen {w L} { return [lindex [split [$w index "$L.0 lineend"] .] 1] }

# Pad a line to at least n chars with spaces (column mode's virtual space).
proc col_pad {line n} {
	set d [expr {$n - [string length $line]}]
	if {$d > 0} { append line [string repeat " " $d] }
	return $line
}

# The line span (L1..L2) and column span (C1..C2) the selection currently covers.
proc col_span {} {
	lassign [split $::col_anchor .] al ac
	lassign [split $::col_caret  .] cl cc
	return [list [expr {min($al,$cl)}] [expr {max($al,$cl)}] \
	             [expr {min($ac,$cc)}] [expr {max($ac,$cc)}]]
}

# Start a column selection at the widget pixel (x,y): anchor = caret = @x,y.
proc col_begin {w x y} {
	if {!$::col_on} return
	set g [group_of_widget $w]
	if {$g ne ""} { focus_group $g }
	focus $w
	$w tag remove sel 1.0 end
	set idx [$w index @$x,$y]
	set ::col_w $w ; set ::col_anchor $idx ; set ::col_caret $idx ; set ::col_active 1
	col_paint
}

# Extend the moving end to @x,y as the mouse drags.
proc col_motion {w x y} {
	if {![col_here $w]} return
	set ::col_caret [$w index @$x,$y]
	col_paint
}

# Destroy the caret bars, stop the blinking, restore the widget's own insert
# bar. Safe to call twice.
proc col_bars_clear {} {
	if {$::col_blink ne ""} { after cancel $::col_blink ; set ::col_blink "" }
	foreach b $::col_bars { catch {destroy $b} }
	set ::col_bars {} ; set ::col_blink_on 1
	if {$::col_insw ne "" && $::col_w ne ""} {
		catch { $::col_w configure -insertwidth $::col_insw }
	}
	set ::col_insw ""
}

# {x y h} of column C on line L of widget w, from the character's bbox. Past
# the line's end: the line-end x plus the missing columns in space widths.
# "" if the line is off screen.
proc col_caret_xy {w L C} {
	set len [col_linelen $w $L]
	if {$C <= $len} {
		set bb [$w bbox $L.$C]
		if {$bb eq ""} { return "" }
		lassign $bb x y bw h
		return [list $x $y $h]
	}
	set bb [$w bbox "$L.$len"]
	if {$bb eq ""} { return "" }
	lassign $bb x y bw h
	set sp [font measure [$w cget -font] " "]
	return [list [expr {$x + $bw + ($C - $len - 1) * $sp}] $y $h]
}

# Draw a thin caret bar on every spanned line at column C. The bars are
# placed over the text and blink together.
proc col_bars_draw {L1 L2 C} {
	col_bars_clear
	set w $::col_w
	set fg [dict get $::theme_colors editor.cursor]
	# Hide the widget's own insert bar; col_bars_clear restores it.
	set iw [$w cget -insertwidth]
	set ::col_insw [expr {$iw == 0 ? 2 : $iw}]
	catch { $w configure -insertwidth 0 }
	# bbox includes -padx and -pady, and `place -in` adds them again: subtract.
	set px [$w cget -padx] ; set py [$w cget -pady]
	for {set L $L1} {$L <= $L2} {incr L} {
		set xy [col_caret_xy $w $L $C]
		if {$xy eq ""} continue
		lassign $xy x y h
		set b $w.colbar$L
		catch {destroy $b}
		frame $b -background $fg -bd 0 -width 1 -height $h
		place $b -in $w -x [expr {$x - $px}] -y [expr {$y - $py}] -width 1 -height $h
		lappend ::col_bars $b
	}
	set ::col_blink_on 1
	set ::col_blink [after 500 col_blink_tick]
}

# Toggle every caret bar's visibility, then reschedule — one shared blink phase.
proc col_blink_tick {} {
	if {![info exists ::col_bars] || $::col_bars eq ""} { set ::col_blink "" ; return }
	set ::col_blink_on [expr {!$::col_blink_on}]
	set fg [dict get $::theme_colors editor.cursor]
	set w $::col_w
	set bg [$w cget -background]
	foreach b $::col_bars {
		catch { $b configure -background [expr {$::col_blink_on ? $fg : $bg}] }
	}
	set ::col_blink [after 500 col_blink_tick]
}

# Repaint the column selection: a `coltag` band per line when it has width,
# else a caret bar on every spanned line.
proc col_paint {} {
	if {!$::col_active} return
	set w $::col_w
	$w tag remove coltag 1.0 end
	lassign [col_span] L1 L2 C1 C2
	if {$C2 > $C1} {
		col_bars_clear
		for {set L $L1} {$L <= $L2} {incr L} {
			set len [col_linelen $w $L]
			set a [expr {min($C1,$len)}] ; set b [expr {min($C2,$len)}]
			if {$b > $a} { $w tag add coltag $L.$a $L.$b }
		}
	}
	catch { $w mark set insert $::col_caret ; $w see insert }
	# Draw the bars AFTER `see` so bbox reflects the final scroll position.
	if {$C2 <= $C1} { col_bars_draw $L1 $L2 $C1 }
}

# Collapse the column selection and hand a single normal caret back.
proc col_clear {} {
	if {!$::col_active} return
	set w $::col_w
	col_bars_clear
	catch { $w tag remove coltag 1.0 end }
	catch { $w mark set insert $::col_caret ; $w see insert }
	set ::col_active 0 ; set ::col_w ""
}

# Apply one column operation across every spanned line as a SINGLE span replace
# (one undo). op: insert (a char/tab), delfwd (Delete), delback (BackSpace).
proc col_edit {op {ch ""}} {
	if {!$::col_active} return
	set w $::col_w
	lassign [col_span] L1 L2 C1 C2
	set start $L1.0 ; set end [$w index "$L2.0 lineend"]
	set block [$w get $start $end]
	set out {} ; set newcol $C1
	foreach line [split $block \n] {
		switch -- $op {
			insert {
				set line [col_pad $line $C1]
				lappend out [string range $line 0 [expr {$C1-1}]]$ch[string range $line $C2 end]
				set newcol [expr {$C1 + [string length $ch]}]
			}
			delfwd {
				if {$C2 > $C1} {
					set line [col_pad $line $C1]
					lappend out [string range $line 0 [expr {$C1-1}]][string range $line $C2 end]
				} elseif {$C1 < [string length $line]} {
					lappend out [string range $line 0 [expr {$C1-1}]][string range $line [expr {$C1+1}] end]
				} else { lappend out $line }
				set newcol $C1
			}
			delback {
				if {$C2 > $C1} {
					set line [col_pad $line $C1]
					lappend out [string range $line 0 [expr {$C1-1}]][string range $line $C2 end]
					set newcol $C1
				} elseif {$C1 > 0} {
					lappend out [string range $line 0 [expr {$C1-2}]][string range $line $C1 end]
					set newcol [expr {$C1 - 1}]
				} else { lappend out $line ; set newcol 0 }
			}
		}
	}
	set newblock [join $out \n]
	if {$newblock eq $block} { return }   ;# no-op (e.g. BackSpace at column 0)
	$w replace $start $end $newblock       ;# proxy -> one buffer.replace -> one undo
	# Back to a caret column at the new column, still live.
	set ::col_anchor $L1.$newcol ; set ::col_caret $L2.$newcol
	col_paint
}

# Key hooks the windows mode binds. Each returns 1 when it consumed the event
# (the binding then breaks), 0 to let normal editing through.
proc col_typed {w ch state} {
	if {![col_here $w]} { return 0 }
	if {$ch eq "" || ($state & 0x0C)} { return 0 }   ;# Control/Alt held, or no char
	if {![string is print -strict $ch]} { return 0 } ;# Tab/Return/BackSpace handled elsewhere
	col_edit insert $ch ; return 1
}
proc col_key {w op} {
	if {![col_here $w]} { return 0 }
	col_edit $op ; return 1
}

# Settings toggle: turning it off ends any live selection, then persist.
proc apply_column_edit {} {
	if {!$::col_on} { col_clear }
	prefs_save
}

# Build editor group `g` and register it in ::grp.
#
#   .eg<g>   ┌ tabs ──────────────────────┐
#            │ gutter │ text         │ vsb │
#            └────────┴ hsb ─────────┴─────┘
#
# The real widget command is renamed to ::real<g>; .eg<g>.t becomes the edit
# proxy. Each group has its own tab strip (D33).
proc make_editor_group {g} {
	set f .eg$g
	frame $f
	frame $f.tabs -background "#bbbbbb"
	text $f.t -wrap none -undo 0 -font [chrome_font 12] -width 80 -height 28 \
		-background white -foreground black -insertbackground black \
		-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
		-yscrollcommand [list edscroll $g] -xscrollcommand [list gridscroll $f.hsb]
	# The gutter (D49). Its wheel scrolls the text.
	canvas $f.gutter -width 1 -highlightthickness 0 -borderwidth 0 -takefocus 0
	bind $f.gutter <MouseWheel> "$f.t yview scroll \[expr {%D > 0 ? -1 : 1}\] units"
	bind $f.gutter <Button-4>   [list $f.t yview scroll -1 units]
	bind $f.gutter <Button-5>   [list $f.t yview scroll  1 units]
	bind $f.gutter <Button-1>   [list gutter_press  $g %y]  ;# click a number selects its line (D61)
	bind $f.gutter <B1-Motion>  [list gutter_motion $g %y]  ;# drag to extend, line-by-line
	editor_zoom_bindings $f.gutter   ;# Ctrl+wheel over the numbers zooms too (D56)
	# Resize, re-wrap, zoom: repaint the gutter and the highlighting (D126).
	bind $f.t <Configure> [list editor_reconfigured $g]
	scrollbar $f.vsb -orient vertical   -command [list $f.t yview]
	scrollbar $f.hsb -orient horizontal -command [list $f.t xview]
	grid $f.tabs   -row 0 -column 0 -columnspan 3 -sticky ew
	bind $f.tabs <Configure> [list tabstrip_on_configure $g]  ;# re-flow tabs on resize (D57)
	grid $f.gutter -row 1 -column 0 -sticky ns
	grid $f.t      -row 1 -column 1 -sticky nsew
	grid $f.vsb    -row 1 -column 2 -sticky ns
	grid $f.hsb    -row 2 -column 1 -sticky ew
	grid rowconfigure    $f 1 -weight 1
	grid columnconfigure $f 1 -weight 1
	rename $f.t ::real$g
	dict set ::grp $g [dict merge [new_group_state] \
		[dict create w ::real$g path $f.t frame $f tabs $f.tabs]]
	proc $f.t {args} "editor_proxy $g {*}\$args"
	editor_bindings $f.t
	editor_zoom_bindings $f.t   ;# Ctrl+scroll / Ctrl +/- / Ctrl+0 zoom the font (D56)
	# The mode's bind tag, between the widget and the Text class (D38).
	bindtags $f.t [linsert [bindtags $f.t] 1 RioMode]
	bind $f.t <Button-1> [list focus_group $g]   ;# clicking a group focuses it
	# The context menu (D108): right-click, the Menu key, Shift+F10. On the
	# widget and with `break`, so it wins over an editing mode.
	# <<ContextMenu>> is the right button on every platform (D136).
	bind $f.t <<ContextMenu>> "editor_context_menu $g %x %y %X %Y ; break"
	bind $f.t <Key-Menu>   "editor_context_key $g ; break"
	bind $f.t <Shift-F10>  "editor_context_key $g ; break"
	# A key-up or a click may have moved the caret: update Ln/Col.
	bind $f.t <KeyRelease>      [list cursor_moved $g]
	bind $f.t <ButtonRelease-1> [list cursor_moved $g]
	# OS file-drop onto the text opens the file (D86). tkdnd does not pass a
	# drop to ancestors, so each text widget is its own target.
	if {$::have_tkdnd && !$::core_remote} {
		tkdnd::drop_target register $f.t DND_Files
		bind $f.t <<Drop>> {dnd_open_files %D}
	}
	return $g
}

# The caret may have moved in group g: move its band, and update the status
# bar if g is the focused group.
proc cursor_moved {g} {
	curline_update $g   ;# per-group: band follows this group's own caret, focused or not
	if {$g eq $::focus} refresh_status
}
# Make group `g` the focused one; ::cur follows its active buffer.
proc focus_group {g} {
	if {$g eq $::focus} return
	set ::focus $g
	set ::cur [gcur $g]
	refresh_all
}
