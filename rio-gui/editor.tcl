# rio-gui/editor.tcl — the editor widget: groups, the edit proxy, gutter, wrap, indent, columns.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# Toggle line wrapping (View menu). With wrap on, lines fold at the word and the
# horizontal scrollbar is meaningless, so it is hidden; with wrap off the bar comes
# back for long lines. Configures every group's real widget (the proxy only guards
# edits) and its own horizontal scrollbar.
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

# The compare panes have no horizontal scrollbar, so wrap is the only way to read
# long lines there; keep them in step with the editor's View ▸ Wrap Lines.
proc cmp_apply_wrap {} {
	set w [expr {$::wrap_lines ? "word" : "none"}]
	.cmp.l.t configure -wrap $w
	.cmp.r.t configure -wrap $w
}

# ---------------------------------------------------------------------------
# Line-number gutter (View ▸ Line Numbers). A thin canvas down the left of each
# editor group showing one number per LOGICAL line, drawn from the text widget's
# own dlineinfo so a wrapped line's number sits at its FIRST display row (VSCode's
# behaviour) and the two never drift. It repaints on every signal that can change what
# the numbers should read: a view move (the widget's -yscrollcommand), a resize/re-wrap
# (<Configure>), a text edit (apply_change) and a tab switch/open (load_buffer). The
# last two matter because an edit that adds/removes lines — or a same-height buffer
# swap — need not move the view, so -yscrollcommand alone would leave stale numbers.
# All coalesced to one idle pass so a fast scroll or a burst of typing paints once. Pure
# display: the numbers live only in the canvas, never in the buffer text (D12).
# ---------------------------------------------------------------------------

# The editor's -yscrollcommand: drive the group's own vertical scrollbar, then mark
# its gutter for repaint (the scrollbar move is exactly our "view changed" signal).
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

# The editor widget changed shape: resized, re-wrapped, or zoomed. Both the gutter and
# the highlight window are derived from the visible line range, so both want re-deriving.
proc editor_reconfigured {g} {
	gutter_mark $g
	hl_vmark $g
}

# The number a gutter row paints for logical line `ln` when the caret sits on line
# `caret`. Absolute normally; with relative numbering on, every line BUT the caret's
# shows its DISTANCE from the caret (vim's hybrid number+relativenumber — the caret line
# keeps its absolute number as a where-am-I anchor). Pure (no Tk) so it unit-tests, where
# the painted glyphs can't (dlineinfo needs a mapped window — see the D49 gutter smoke).
proc gutter_label {ln caret relative} {
	return [expr {$relative && $ln != $caret ? abs($ln - $caret) : $ln}]
}

# Repaint group g's line-number canvas to match its visible lines. The width (sized
# to the last line's digit count, min two) is set even off-screen so it is stable
# without a render; the numbers themselves are drawn only once the canvas is mapped —
# dlineinfo needs a real geometry. Walks the visible logical lines (@0,0 down to the
# bottom pixel); a line with no display box (scrolled past / elided) is skipped, so
# wrapped lines fall out naturally. No-op when the gutter is off or the group is gone.
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

# View-menu toggle: show or hide every group's gutter, then persist. Showing it
# re-grids the canvas into column 0 (grid remembers the cell) and paints it; hiding
# grid-removes it. The gutter's colours ride apply_theme (restyle_group).
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

# Click a gutter number to select its whole logical line; drag to extend the selection
# line-by-line, up or down (D61). The gutter shares the text's vertical extent and scroll
# position (both grid row 1) and gutter_redraw draws each number at the text widget's own
# dlineinfo y, so a canvas y inverts back through `index @0,$y`. We anchor at the pressed
# line and select the inclusive span anchor..current; the `$b.0 lineend +1c` end reaches
# past the newline for a full-width line select (the D60 curline trick) and clamps to `end`
# on the last, newline-less line. The gutter is -takefocus 0, so we move keyboard focus to
# the text ourselves; cursor_moved refreshes the status Ln/Col and the D60 current-line band.
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
# Current-line highlight (View ▸ Highlight Current Line). A full-width background
# band on the LOGICAL line the insert caret sits on, one per editor group so a split
# shows the band under each pane's own caret. Pure display: a `curline` tag, coloured
# by restyle_group from the editor.currentline role and lowered under selection / find
# so those paint over it. The range is `insert linestart` … `insert lineend +1c` — the
# +1c reaches into the newline so the band spans the full width (selrow's trick); a
# wrapped logical line is covered across all its display rows. Updated wherever the
# caret can move: cursor_moved (typing / arrows / click), refresh_status (open / switch
# / jump / reload, which all route through it) and the search-result jump.
# ---------------------------------------------------------------------------

# Repaint group g's caret-line band to its current insert position (or clear it when
# the feature is off / the group is gone).
proc curline_update {g} {
	if {![dict exists $::grp $g]} return
	set t [gw $g]
	if {$::relative_line_numbers} { gutter_mark $g }  ;# relative gutter is caret-anchored — repaint as the caret moves (idle-coalesced; gutter_redraw no-ops when the gutter is hidden)
	$t tag remove curline 1.0 end
	if {!$::highlight_current_line} return
	$t tag add curline "insert linestart" "insert lineend +1c"
}

# View-menu toggle: re-band (or clear) every group, then persist.
proc apply_curline {} {
	foreach g $::groups { curline_update $g }
	prefs_save
}

# View-menu toggle: relative numbering is a modifier on the shown gutter, so just repaint
# every group's gutter (gutter_redraw no-ops when the gutter is hidden), then persist. The
# gutter's width stays sized to the absolute last-line digits, so toggling relative — or
# moving the caret — never reflows it.
proc apply_relnum {} {
	foreach g $::groups { gutter_redraw $g }
	prefs_save
}

# ---------------------------------------------------------------------------
# Wrap indent (View ▸ Indent Wrapped Lines). With line wrap on, Tk shows a
# logical line's leading indentation on its FIRST display line only; the wrapped
# continuation lines fall back to the left margin. With this on, each continuation
# line is indented to sit under its own line's first non-whitespace character —
# VSCode's "wrappingIndent: same". It is a pure display layer: a per-line
# -lmargin2 tag sized to the line's leading whitespace, so it works on plain
# (un-highlighted) files too. Tk tags ride with the text on insert/delete, so an
# edit only recomputes the lines it actually touched (apply_change), never the
# whole buffer. No visible effect while wrap is off — the tags simply wait.
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

# Pixels per monospace column of the editor font (rio's editor font is monospace
# by design; a proportional font would only skew the alignment, never break it).
proc wrapind_colpx {} { return [font measure RioEditorFont "0"] }

# The wrapind:<cols> tags currently defined on widget t.
proc wrapind_tags {t} {
	set out {}
	foreach tag [$t tag names] { if {[string match wrapind:* $tag]} { lappend out $tag } }
	return $out
}

# (Re)compute the wrap indent for lines L1..L2 of t: drop any old wrapind tag on
# each line, then — when enabled and the line is indented — tag it with a
# wrapind:<cols> tag whose -lmargin2 matches that indentation. One shared tag per
# distinct column count, created on demand.
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

# Recolour every site's tab strip to the current theme (the active tab stands out,
# the rest recede). Called from apply_theme; render_tabs does the same colouring
# when a layout pass rebuilds a strip. Guarded so it can run before the sites exist.
proc restyle_tabs {} {
	foreach s {left right bottom} {
		if {[winfo exists .site$s.tabs]} { render_tabs $s }
	}
}

# ---------------------------------------------------------------------------
# Editor split (D33): create/destroy the second group and move tabs across.
# v1 is at most two groups; ids are the free slot in {0,1} so a collapsed group's slot
# is reused on the next split.
# ---------------------------------------------------------------------------
# The other group (v1: at most two), or "" if `g` is the only one.
proc other_group {g} {
	foreach o $::groups { if {$o ne $g} { return $o } }
	return ""
}

# Which group's pane does widget `w` live under? Walk up from `w` to a group frame
# (.eg<g>) and return its id, or "" if `w` is outside every group. `group_at` layers
# the screen-coordinate lookup on top for drag-and-drop; the widget walk is split out
# so it can be unit-tested without real pointer geometry (split.tcl).
proc group_of_widget {w} {
	while {$w ne ""} {
		foreach g $::groups { if {$w eq [gget $g frame]} { return $g } }
		set w [winfo parent $w]
	}
	return ""
}
proc group_at {X Y} { group_of_widget [winfo containing $X $Y] }

# Tear down group `g`'s widgets and its leftover proxy proc, and drop it from ::grp.
# (Destroying the frame removes the real widget command; the proxy at .eg<g>.t is a
# plain proc, so it must be renamed away or the slot can't be rebuilt on a re-split.)
proc destroy_editor_group {g} {
	set path [gget $g path] ; set w [gw $g]
	set ::tabstrip_w [dict remove $::tabstrip_w $g]  ;# forget the strip's cached width (D57)
	catch {destroy [gget $g frame]}
	catch {rename $path ""}
	catch {rename $w ""}
	dict unset ::grp $g
}

# Bring up an empty second editor group in the free slot, styled and wrap-synced to
# match. Returns its id. Callers give it a buffer (split_editor) or move one in.
proc add_group {} {
	set g [expr {[lsearch -exact $::groups 0] < 0 ? 0 : 1}]
	make_editor_group $g
	lappend ::groups $g
	relayout_groups
	restyle_group $g
	apply_wrap          ;# sync the new group's wrap mode + horizontal scrollbar
	apply_line_numbers  ;# sync the new group's gutter to ::line_numbers
	# The shared RioMode tag already covers the new widget's keys; re-attaching
	# (idempotent by contract, D38) lets the active mode set up its per-group
	# state too — vi's cursor shape and normal/insert state for the new half.
	if {$::editmode_active ne ""} { catch {rio::modes::attach $::editmode_active RioMode} }
	after idle even_split   ;# a new split opens 50/50; later user sash drags are kept
	return $g
}

# Fold group `g` into the other one: its tabs move over (appended), its widgets are
# destroyed, and focus lands on the survivor. Never collapses the sole group.
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

# Split the editor: open a second group with a fresh scratch buffer and focus it. A
# no-op if already split. (Use Move Tab to Other Group to send an open file across.)
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

# Move buffer `id` out of group `src` into the other group (creating the split if
# needed) and follow it there. If `src` empties it collapses — so moving the only tab
# is a harmless no-op round-trip, and peeling one off a multi-tab group gives a real
# side-by-side (D33: a buffer lives in exactly one group). `id` need not be src's
# active tab (the context menu can move any tab).
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

# A one-shot undo break (D90). The core merges a run of single-character edits
# into one undo step — right for typing, wrong for a repeated command: vi's `x`
# pressed three times is three one-character deletions the core cannot tell from
# three presses of Delete. A mode about to dispatch a discrete command arms this,
# and the next edit through the proxy starts its own undo step.
set ::undo_break 0
proc undo_break {} { set ::undo_break 1 }

# The coalesce flag for the edit being sent now, consuming any armed break.
proc undo_coalesce {} {
	if {!$::undo_break} { return 1 }
	set ::undo_break 0
	return 0
}

# The per-widget proxy: an insert/delete becomes a buffer.replace on THIS group's
# active buffer; everything else passes straight through to the real widget command.
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
			# .t delete <index1> ?index2?  — compute i2 WITHOUT expr. A Tk text index
			# like "1.10" passed through expr is coerced to the float 1.1, silently
			# corrupting the column: backspace would then no-op at every column 10, 20,
			# 30, … (and forward/range deletes ending there too).
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
			# .t replace <index1> <index2> <chars> — one edit, one undo step
			# (paste over a selection). Same index discipline as delete: no expr.
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
# Shared clipboard actions on an editor widget (D38). One implementation serves
# the Edit menu and whichever editing mode binds keys to them (the Windows mode
# does), so menu and keyboard can never drift apart. `w` is a group's PROXY path:
# the cut/paste edits run through editor_proxy and reach the core; copy only
# reads. Paste REPLACES a selection (the Windows/VSCode convention — Tk's own
# x11 <<Paste>> leaves it in place) as a single replace, i.e. one undo step.
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
# Block indent / dedent (D38). The Windows mode binds these to Tab / Shift+Tab.
# With a selection, every line the selection touches shifts by one tab as a
# SINGLE core edit (one undo step, one round-trip): existing leading tabs and
# spaces are kept and pushed along, never replaced — so a selection is indented,
# never deleted (Tk's own <Tab> would delete it). Tab with no selection inserts a
# plain tab at the caret (the Notepad feel); Shift+Tab with no selection dedents
# the caret's line. The block edits go through the group PROXY (`w`) to the core.
# Indenting/dedenting never changes the line count, so the block is re-selected
# afterward — press Tab again to add another level.
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

# Shift the line span the selection (else the caret) covers by one indent level:
# dir 1 adds a tab in front of each line, dir -1 removes one level. A selection
# that ends at column 0 does NOT pull in that trailing line — its text is
# untouched (the VSCode/Notepad++ rule).
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
		# Caret-only dedent: keep the caret over the same character by pulling it
		# left by however much whitespace this line lost (clamped to line start).
		set col [expr {$caretcol - $removedfirst}] ; if {$col < 0} { set col 0 }
		$w mark set insert $l1.$col
	}
	$w see insert
}

# One indent level off the front of a line: a leading tab, else up to a
# tab-stop's worth (4) of leading spaces. A line with no leading whitespace is
# returned unchanged.
proc editor_dedent_one {ln} {
	if {[string index $ln 0] eq "\t"} { return [string range $ln 1 end] }
	set n 0
	while {$n < 4 && [string index $ln $n] eq " "} { incr n }
	return [string range $ln $n end]
}

# ---------------------------------------------------------------------------
# Column / block editing (D40). Ctrl+Shift+drag makes a vertical,
# multi-line cursor. Its zero-width form is a CARET COLUMN: typing / Backspace /
# Delete / Tab act at one column on EVERY spanned line; drag a width and typing
# overwrites that rectangular slice per line. Off by default (::col_on), a
# Settings toggle. Notepad++'s real gesture is Alt+drag, but Linux/X11 window
# managers grab Alt+drag to move the window, so rio uses Ctrl+Shift+drag.
#
# The whole feature is GUI-side. A column operation is emitted as ONE
# buffer.replace over L1.0..L2.lineend with the transformed block, so it is a
# single undo step — the same shape as replace_all and the D38 block-indent. All
# these procs work on the group PROXY path `w` (edits route through editor_proxy
# to the core; reads/tags/marks pass through). The windows mode binds them,
# pref-gated; vi/emacs keep their own block notions. Columns are CHARACTER
# columns (a tab inside the band may look misaligned — a documented v1 edge).
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

# Destroy the placed caret bars, stop the blink loop, and give the widget its native
# insert bar back (col_bars_draw hides it so the caret line blinks in phase with the
# rest rather than showing two out-of-phase bars). Idempotent.
proc col_bars_clear {} {
	if {$::col_blink ne ""} { after cancel $::col_blink ; set ::col_blink "" }
	foreach b $::col_bars { catch {destroy $b} }
	set ::col_bars {} ; set ::col_blink_on 1
	if {$::col_insw ne "" && $::col_w ne ""} {
		catch { $::col_w configure -insertwidth $::col_insw }
	}
	set ::col_insw ""
}

# The x pixel of column C on line L of widget w — bbox of the character there, or,
# past the line's end (column mode's virtual space), the line-end x plus the
# remaining columns' worth of a space glyph. "" if the line isn't laid out (off
# screen). y/h come from the same bbox so bars match the line height.
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

# Draw one thin caret bar per spanned line at column C (the zero-width form). The
# bars overlay the text via place; they blink together via col_blink_tick, matching
# the look of the normal caret across every line rather than a solid block.
proc col_bars_draw {L1 L2 C} {
	col_bars_clear
	set w $::col_w
	set fg [dict get $::theme_colors editor.cursor]
	# Hide the native insert bar so the caret line blinks with the drawn bars, not
	# against them; col_bars_clear restores it (saved width, default 2 if unset).
	set iw [$w cget -insertwidth]
	set ::col_insw [expr {$iw == 0 ? 2 : $iw}]
	catch { $w configure -insertwidth 0 }
	# bbox coordinates already include the widget's -padx/-pady, but `place -in`
	# adds them again — a double-count that lands the bar ~half a cell into the
	# glyph. Subtract them so the bar sits on the true cell boundary (bbox.x), the
	# exact spot Tk draws the native insert bar. Font-size independent, no fudging.
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

# Repaint the block highlight (coltag) or the caret column. A width selection is a
# rectangular coltag band per line; the zero-width form is a thin blinking caret
# bar on every spanned line (col_bars_draw), so it reads as one cursor stretched
# down the column rather than a stack of solid blocks. The caret line also carries
# Tk's own insert bar at ::col_caret.
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
	# Collapse to a caret column at the new column, same line span; keep it live so
	# the next keystroke keeps typing down the column.
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

# Build editor group `g`: its frame (.eg<g>) with a tab strip on top and the text
# widget + scrollbars below, the renamed real command, the proxy, and the key/focus
# bindings. Registers the group in ::grp. The literal font is replaced by
# RioEditorFont in the next apply_theme. Each group owns its OWN tab strip (D33) — a
# tab lives in exactly one group — so the strip is gridded inside the group frame,
# spanning the text + scrollbar columns, with refresh_tabs filling it per group.
proc make_editor_group {g} {
	set f .eg$g
	frame $f
	frame $f.tabs -background "#bbbbbb"
	text $f.t -wrap none -undo 0 -font [chrome_font 12] -width 80 -height 28 \
		-background white -foreground black -insertbackground black \
		-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
		-yscrollcommand [list edscroll $g] -xscrollcommand [list gridscroll $f.hsb]
	# The line-number gutter (D49): a thin, unfocusable canvas in column 0 that
	# gutter_redraw paints from the text widget's dlineinfo. Its wheel forwards to
	# the text so a scroll begun over the numbers still moves the buffer.
	canvas $f.gutter -width 1 -highlightthickness 0 -borderwidth 0 -takefocus 0
	bind $f.gutter <MouseWheel> "$f.t yview scroll \[expr {%D > 0 ? -1 : 1}\] units"
	bind $f.gutter <Button-4>   [list $f.t yview scroll -1 units]
	bind $f.gutter <Button-5>   [list $f.t yview scroll  1 units]
	bind $f.gutter <Button-1>   [list gutter_press  $g %y]  ;# click a number selects its line (D61)
	bind $f.gutter <B1-Motion>  [list gutter_motion $g %y]  ;# drag to extend, line-by-line
	editor_zoom_bindings $f.gutter   ;# Ctrl+wheel over the numbers zooms too (D56)
	# Resize / re-wrap / font zoom → repaint the gutter, and re-check the highlight
	# window (D126): this is also where a freshly split group first learns its height.
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
	# Slot the editing-mode tag between the widget (app chords) and the Text class
	# (Tk defaults) — the D38 precedence order. The tag is SHARED, so whatever mode
	# is attached covers this group with no per-widget rebinding.
	bindtags $f.t [linsert [bindtags $f.t] 1 RioMode]
	bind $f.t <Button-1> [list focus_group $g]   ;# clicking a group focuses it
	# Right-click opens the editor's context menu (D108); the Menu key and Shift+F10
	# open the same one at the caret. Bound on the WIDGET, so they sit ahead of the
	# RioMode tag in the D38 precedence order — the app's menu wins over anything an
	# editing mode might put on the right button — and `break` stops the rest of the
	# chain. <<ContextMenu>> is the right button on every platform (D136, see rl_init).
	bind $f.t <<ContextMenu>> "editor_context_menu $g %x %y %X %Y ; break"
	bind $f.t <Key-Menu>   "editor_context_key $g ; break"
	bind $f.t <Shift-F10>  "editor_context_key $g ; break"
	# Keep the status bar's Ln/Col segment live: any key-up or click-release may have
	# moved the insert mark (arrows, typing, click-to-place). Cheap; edits already
	# refresh, this covers pure navigation. Guarded on focus so a stray event is a no-op.
	bind $f.t <KeyRelease>      [list cursor_moved $g]
	bind $f.t <ButtonRelease-1> [list cursor_moved $g]
	# OS file-drop onto the editor text opens the file (D86). tkdnd doesn't bubble a drop
	# to ancestors, so each group's text widget registers as its own target (the toplevel,
	# below, covers the docks and tab strips); every drop routes to the one dnd_open_files.
	# Optional extension + local core only — a no-op in a headless run (no tkdnd there).
	if {$::have_tkdnd && !$::core_remote} {
		tkdnd::drop_target register $f.t DND_Files
		bind $f.t <<Drop>> {dnd_open_files %D}
	}
	return $g
}

# Make group `g` the focused one (::cur mirrors its active buffer). Tk moves keyboard
# focus on a click itself; this just repoints our state and repaints the chrome.
# A cursor-moving event fired in group g; repaint the status only when g is the
# focused group (a background group never owns the shown Ln/Col).
proc cursor_moved {g} {
	curline_update $g   ;# per-group: band follows this group's own caret, focused or not
	if {$g eq $::focus} refresh_status
}
proc focus_group {g} {
	if {$g eq $::focus} return
	set ::focus $g
	set ::cur [gcur $g]
	refresh_all
}
