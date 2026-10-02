# rio-gui/theme.tcl — the theme applier and the editor font.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# The editor font picker (D56): a family list, a size spinner, a live
# preview. OK sets the override; "Use Theme Font" clears it.
proc editor_font_preview_update {w} {
	if {![winfo exists $w]} return
	set sel [$w.body.fam.list curselection]
	if {$sel ne ""} { set ::efont_family [$w.body.fam.list get $sel] }
	set sz $::efont_size
	if {![string is integer -strict $sz] || $sz < 5 || $sz > 72} { set sz [editor_font_size_now] }
	catch {$w.preview configure -font [list $::efont_family $sz]}
}

proc editor_font_dialog {} {
	set w .efont
	destroy $w
	toplevel $w
	wm title $w "Editor Font"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	set bg [dict get $c ui.bg] ; set fg [dict get $c ui.fg]
	$w configure -background $bg
	# Pre-select the override, else the real family in use. `font actual`
	# resolves the theme's alias `monospace`, which the list does not have.
	set ::efont_family [expr {$::editor_font_family ne "" \
		? $::editor_font_family : [font actual RioEditorFont -family]}]
	set ::efont_size   [editor_font_size_now]

	frame $w.body -background $bg
	frame $w.body.fam -background $bg
	label $w.body.fam.l -text "Family" -anchor w -font RioUIFont -background $bg -foreground $fg
	listbox $w.body.fam.list -height 12 -width 30 -font RioUIFont -exportselection 0 \
		-activestyle none -yscrollcommand [list $w.body.fam.sb set]
	scrollbar $w.body.fam.sb -orient vertical -command [list $w.body.fam.list yview]
	grid $w.body.fam.l    -row 0 -column 0 -columnspan 2 -sticky w
	grid $w.body.fam.list -row 1 -column 0 -sticky nsew
	grid $w.body.fam.sb   -row 1 -column 1 -sticky ns
	set fams [lsort -unique [font families]]
	foreach fam $fams { $w.body.fam.list insert end $fam }
	set idx [lsearch -exact $fams $::efont_family]
	if {$idx < 0} { set idx [lsearch -nocase $fams $::efont_family] }
	if {$idx >= 0} { $w.body.fam.list selection set $idx ; $w.body.fam.list see $idx }

	frame $w.body.sz -background $bg
	label $w.body.sz.l -text "Size" -anchor w -font RioUIFont -background $bg -foreground $fg
	spinbox $w.body.sz.v -from 5 -to 72 -width 5 -font RioUIFont -textvariable ::efont_size \
		-command [list editor_font_preview_update $w]
	grid $w.body.sz.l -row 0 -column 0 -sticky w
	grid $w.body.sz.v -row 1 -column 0 -sticky w
	grid $w.body.fam -row 0 -column 0 -sticky nsew -padx {8 6} -pady 8
	grid $w.body.sz  -row 0 -column 1 -sticky nw   -padx {0 8} -pady 8

	label $w.preview -text "AaBbCc 0123  — the quick brown fox" -anchor w \
		-relief sunken -borderwidth 1 -padx 6 -pady 6 \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg]
	frame $w.btns -background $bg
	button $w.btns.ok    -text OK     -font RioUIFont -command [list editor_font_apply_dialog $w]
	button $w.btns.theme -text "Use Theme Font" -font RioUIFont -command [list editor_font_reset_dialog $w]
	button $w.btns.cancel -text Cancel -font RioUIFont -command [list destroy $w]
	pack $w.btns.cancel $w.btns.ok -side right -padx 3
	pack $w.btns.theme -side left -padx 3

	grid $w.body    -row 0 -column 0 -sticky nsew
	grid $w.preview -row 1 -column 0 -sticky ew -padx 8 -pady {0 6}
	grid $w.btns    -row 2 -column 0 -sticky ew -padx 5 -pady {0 8}

	bind $w.body.fam.list <<ListboxSelect>> [list editor_font_preview_update $w]
	bind $w.body.sz.v <KeyRelease> [list editor_font_preview_update $w]
	bind $w <Escape> [list destroy $w]
	editor_font_preview_update $w
	catch {grab $w}
	focus $w.body.fam.list
}

# OK: the picked family and size become the override.
proc editor_font_apply_dialog {w} {
	set sel [$w.body.fam.list curselection]
	if {$sel ne ""} { set ::editor_font_family [$w.body.fam.list get $sel] }
	set sz $::efont_size
	if {[string is integer -strict $sz] && $sz >= 5 && $sz <= 72} { set ::editor_font_size $sz }
	destroy $w
	apply_editor_font
	prefs_save
}

# "Use Theme Font": clear both overrides.
proc editor_font_reset_dialog {w} {
	set ::editor_font_family ""
	set ::editor_font_size 0
	destroy $w
	apply_editor_font
	prefs_save
}

# ---------------------------------------------------------------------------
# The theme applier (D24). A theme is data: a table of roles, served by
# the core (theme.get). Mapping roles onto Tk happens only here.
#
#   theme.get -> {colors {editor.bg #fff ...} fonts {RioUIFont {...} ...}}
#     fonts    named fonts: reconfigure one and every widget follows
#     colors   set on each widget: the option database only reaches
#              widgets created later
# ---------------------------------------------------------------------------
set ::theme_colors {} ;# active colour roles, consulted by refresh_tabs

# Set RioEditorFont: the theme's values with the user's override on top
# (D56). Then redraw what depends on the glyph width: gutter and wrap
# indent. Does nothing before the first apply_theme.
proc apply_editor_font {} {
	if {[lsearch -exact [font names] RioEditorFont] < 0} return
	set fam [expr {$::editor_font_family ne "" ? $::editor_font_family : $::editor_theme_family}]
	set sz  [expr {$::editor_font_size  > 0  ? $::editor_font_size   : $::editor_theme_size}]
	font configure RioEditorFont -family [mono_family $fam] -size $sz
	foreach g $::groups {
		if {![winfo exists [gget $g path]]} continue
		wrapind_refont [gw $g]
		gutter_redraw $g
	}
}

# The editor size in points: the override, else the theme's.
proc editor_font_size_now {} {
	return [expr {$::editor_font_size > 0 ? $::editor_font_size : $::editor_theme_size}]
}

# Zoom by `delta` points, within 5..72. Sets an absolute size override, so
# the zoom survives a theme switch.
proc editor_zoom {delta} {
	set sz [expr {[editor_font_size_now] + $delta}]
	if {$sz < 5}  { set sz 5 }
	if {$sz > 72} { set sz 72 }
	if {$sz == [editor_font_size_now] && $::editor_font_size > 0} return
	set ::editor_font_size $sz
	apply_editor_font
	prefs_save
}

# Reset the zoom: drop the size override. The family override stays.
proc editor_zoom_reset {} {
	if {$::editor_font_size == 0} return
	set ::editor_font_size 0
	apply_editor_font
	prefs_save
}

# Create or reconfigure the theme's named fonts.
proc ensure_fonts {fonts} {
	dict for {name spec} $fonts {
		set sz [dict get $spec size]
		if {$name ne "RioEditorFont"} { set sz [ui_size $sz] } ;# D135's Aqua floor
		set opts [list -family [mono_family [dict get $spec family]] -size $sz]
		if {[lsearch -exact [font names] $name] >= 0} {
			font configure $name {*}$opts
		} else {
			font create $name {*}$opts
		}
	}
}

# Colour one editor group from ::theme_colors: text, frame, tab strip,
# gutter and tags. For apply_theme and for a new group.
#
# Tag order: curline at the bottom; sel, then coltag, on top.
proc restyle_group {g} {
	set c $::theme_colors
	set t [gw $g]
	$t configure -font RioEditorFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor] \
		-selectbackground [dict get $c editor.selection]
	wrapind_refont $t   ;# the font's column width may have moved — keep margins in step
	[gget $g frame] configure -background [dict get $c editor.bg]
	[gget $g tabs]  configure -background [dict get $c tab.bar.bg]
	[gget $g frame].gutter configure -background [dict get $c editor.bg]
	gutter_redraw $g    ;# gutter.fg / font may have moved — repaint the numbers
	if {[info procs rio::syntax::tokens] ne ""} {
		foreach tok [rio::syntax::tokens] {
			set role syntax.$tok
			set col [expr {[dict exists $c $role] ? [dict get $c $role] : [dict get $c editor.fg]}]
			$t tag configure syn:$tok -foreground $col
		}
	}
	# Find matches (D36).
	set fm [expr {[dict exists $c editor.findmatch] \
		? [dict get $c editor.findmatch] : [dict get $c editor.selection]}]
	$t tag configure findmatch -background $fm
	# A column selection (D40) has the selection colour.
	$t tag configure coltag -background [dict get $c editor.selection]
	# The caret line (D60): the theme's role, else a faint blend.
	set cl [expr {[dict exists $c editor.currentline] \
		? [dict get $c editor.currentline] \
		: [blend_hex [dict get $c editor.bg] [dict get $c editor.fg] 8]}]
	$t tag configure curline -background $cl
	$t tag lower curline
	$t tag raise sel
	$t tag raise coltag
}

# Apply a theme to every widget that exists.
proc apply_theme {theme} {
	set c [dict get $theme colors]
	set ::theme_colors $c
	set ::aqua_appearance [aqua_appearance_for [dict get $c ui.bg]]
	aqua_appearance_all   ;# D135: native controls follow the theme's lightness (Aqua only)
	ensure_fonts [dict get $theme fonts]
	# Record the theme's editor font, then put the user's override back on
	# top (D56), before the groups measure the font.
	set _ef [dict get $theme fonts RioEditorFont]
	set ::editor_theme_family [dict get $_ef family]
	set ::editor_theme_size   [dict get $_ef size]
	apply_editor_font
	# The editor groups (D33).
	foreach _g $::groups { restyle_group $_g }
	# Status bar and sashes. refresh_tabs, at the end, colours the tabs.
	.status configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.sash configure -background [dict get $c tab.bar.bg]   ;# the dock divider/grip
	.bsash configure -background [dict get $c tab.bar.bg]  ;# the bottom-dock height grip
	# The dock sites and the files and git panes: the UI role.
	foreach w {.siteleft .siteleft.tabs .siteleft.body .siteright .siteright.tabs .siteright.body \
	           .sitebottom .sitebottom.tabs .sitebottom.body \
	           .pfiles .pfiles.hdr .pgit .pgit.hdr} {
		$w configure -background [dict get $c ui.bg]
	}
	foreach w {.pfiles.hdr.head .pfiles.hdr.refresh .pfiles.hdr.hidden \
	           .pgit.hdr.branch .pgit.hdr.refresh .pgit.hdr.discard} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	# The rich lists (D42, D43): the editor surface, a selection band, a
	# fainter hover band beneath it.
	set fbg [dict get $c editor.bg]
	foreach well {.pfiles.well .pgit.well} {
		$well configure -background $fbg
		set body $well.body
		$body configure -font RioUIFont -background $fbg -foreground [dict get $c ui.fg]
		$body tag configure selrow   -background [dict get $c editor.selection]
		$body tag configure hoverrow -background [blend_hex $fbg [dict get $c editor.selection] 25]
		$body tag raise selrow
	}
	# Files pane (D43): muted glyphs; git flags added, removed, modified.
	.pfiles.well.body tag configure navicon  -foreground [blend_hex [dict get $c ui.fg] $fbg 35]
	.pfiles.well.body tag configure navadd   -foreground [dict get $c diff.added]
	.pfiles.well.body tag configure navdel   -foreground [dict get $c diff.removed]
	.pfiles.well.body tag configure navmod   -foreground [dict get $c accent]
	.pfiles.well.body tag configure navdirty -foreground [blend_hex [dict get $c accent] $fbg 40]
	# The git list's status characters: the same colours.
	.pgit.well.body tag configure gitadd -foreground [dict get $c diff.added]
	.pgit.well.body tag configure gitdel -foreground [dict get $c diff.removed]
	.pgit.well.body tag configure gitmod -foreground [dict get $c accent]
	# The diff area is code, so it takes the editor surface.
	.pgit.diff configure -font RioEditorFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg]
	# The commit bar (D45): entries on the editor surface, a place to type.
	.pgit.commit configure -background [dict get $c ui.bg]
	.pgit.commit.go configure -font RioUIFont
	.pgit.commit.msg configure -font RioUIFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor]
	# The placeholder: muted.
	.pgit.commit.msg.ph configure -font RioUIFont \
		-background [dict get $c editor.bg] \
		-foreground [blend_hex [dict get $c editor.fg] [dict get $c editor.bg] 50]
	# The description body: like the summary.
	.pgit.commit.more configure -font RioUIFont
	.pgit.commit.body configure -font RioUIFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor]
	.pgit.commit.body.ph configure -font RioUIFont \
		-background [dict get $c editor.bg] \
		-foreground [blend_hex [dict get $c editor.fg] [dict get $c editor.bg] 50]
	# The chat pane (D26): the chat.* roles; controls take the accent.
	.chat configure -background [dict get $c chat.bg]
	.chat.hdr configure -background [dict get $c chat.bg]
	.chat.hdr.title configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg]
	.chat.hdr.clear configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c accent]
	.chat.hdr.mode configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c accent]
	.chat.hdr.mode.m configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.chat.log configure -font RioChatFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg]
	.chat.input configure -font RioChatFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg] \
		-insertbackground [dict get $c chat.fg]
	.chat.send configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	# The bottom strip: the agent selector is a control, so accent (D68);
	# the busy indicator is not.
	.chat.status configure -background [dict get $c tab.bar.bg]
	.chat.status.sel configure -font RioUIFont \
		-background [dict get $c tab.bar.bg] -foreground [dict get $c accent]
	.chat.status.sel.m configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.chat.status.busy configure -font RioUIFont \
		-background [dict get $c tab.bar.bg] -foreground [dict get $c ui.fg]
	# Speaker headers: a full-width band, so a turn is easy to find. You
	# and Agent have different tints.
	.chat.log tag configure agent-label -font RioUIFont -foreground [dict get $c accent] \
		-background [dict get $c ui.bg] -spacing1 4 -spacing3 2
	.chat.log tag configure you-label   -font RioUIFont -foreground [dict get $c chat.fg] \
		-background [dict get $c editor.selection] -spacing1 4 -spacing3 2
	.chat.log tag configure error-label -font RioUIFont -foreground [dict get $c error]
	.chat.log tag configure tool        -font RioUIFont -foreground [dict get $c gutter.fg]
	.chat.log tag configure tool-error  -font RioUIFont -foreground [dict get $c error]
	# Reasoning: muted like the tool lines, and indented, so it is visibly
	# not the answer.
	.chat.log tag configure thinking    -font RioUIFont -foreground [dict get $c gutter.fg] \
		-lmargin1 12 -lmargin2 12
	.chat.log tag configure diff-add    -font RioUIFont -foreground [dict get $c diff.added]
	.chat.log tag configure diff-del    -font RioUIFont -foreground [dict get $c diff.removed]
	.chat.approve configure -background [dict get $c chat.bg]
	.chat.approve.lbl configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg]
	.chat.approve.yes configure -font RioUIFont
	.chat.approve.no  configure -font RioUIFont
	.chat.approve.cmp configure -font RioUIFont
	.chat.approve.plan configure -font RioUIFont
	.chat.approve.always configure -font RioUIFont
	.chat.approve.always.m configure -font RioUIFont
	.csash configure -background [dict get $c tab.bar.bg]
	.chat.isash configure -background [dict get $c tab.bar.bg]
	# The find bar (D36): entries on the editor surface.
	.find configure -background [dict get $c ui.bg]
	foreach w {.find.fl .find.rl .find.count .find.close .find.case .find.word .find.regex} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	foreach w {.find.case .find.word .find.regex} {
		$w configure -activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
	}
	foreach w {.find.next .find.prev .find.rep .find.repall} {
		$w configure -font RioUIFont
	}
	foreach w {.find.e .find.re} {
		$w configure -font RioChatFont \
			-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
			-insertbackground [dict get $c editor.cursor]
	}
	# The Search panel (D52): like the find bar; its list like the dock
	# panes'. File header rows take the accent.
	foreach w {.results .results.hdr .results.rep} { $w configure -background [dict get $c ui.bg] }
	foreach w {.results.hdr.l .results.hdr.count .results.hdr.close .results.hdr.case .results.hdr.word .results.hdr.regex .results.rep.l} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	.results.rep.all configure -font RioUIFont
	foreach w {.results.hdr.case .results.hdr.word .results.hdr.regex} {
		$w configure -activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
	}
	# The scope menu.
	.results.hdr.scope configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
	.results.hdr.scope.menu configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c editor.selection] -activeforeground [dict get $c ui.fg]
	foreach w {.results.hdr.e .results.rep.e} {
		$w configure -font RioChatFont \
			-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
			-insertbackground [dict get $c editor.cursor]
	}
	.results.well configure -background [dict get $c editor.bg]
	set rbody .results.well.body
	$rbody configure -font RioEditorFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg]
	$rbody tag configure selrow   -background [dict get $c editor.selection]
	$rbody tag configure hoverrow -background [blend_hex [dict get $c editor.bg] [dict get $c editor.selection] 25]
	$rbody tag configure fifile -foreground [dict get $c accent]
	# A hit: the diff-added background (D51), above the selection band so
	# it shows on the selected row.
	$rbody tag configure fimatch -background [dict get $c diff.added.bg]
	$rbody tag raise selrow
	$rbody tag raise fimatch
	# The compare view (D28): removed and added rows are tinted, fillers
	# grey.
	foreach w {.cmp.l.hdr .cmp.r.hdr} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	foreach w {.cmp.l.t .cmp.r.t} {
		$w configure -font RioEditorFont \
			-background [dict get $c editor.bg] -foreground [dict get $c editor.fg]
		$w tag configure del    -background [dict get $c diff.removed.bg] -foreground [dict get $c diff.removed]
		$w tag configure add    -background [dict get $c diff.added.bg] -foreground [dict get $c diff.added]
		$w tag configure filler -background [dict get $c ui.bg]
	}
	.cmp.sb configure -background [dict get $c ui.bg]
	.cmp.bar configure -background [dict get $c ui.bg]
	.cmp.bar.close configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	restyle_tabs
	help_restyle   ;# the help viewer, if it is open — it outlives a theme change (D99)
	plan_restyle   ;# and the plan view, which outlives one the same way (D101)
	# Default fonts for widgets created later.
	option add *Text.font RioEditorFont
	option add *Label.font RioUIFont
	if {[dict size $::buffers]} refresh_tabs
	aqua_native_colours_all   ;# D135: leave native buttons to the appearance (Aqua only)
}

# Switch to theme `name`: fetch it from the core, apply, save.
proc do_theme {name} {
	set resp [rio_call theme.get [dict create name $name]]
	if {[dict get $resp ok]} {
		set ::theme_name $name
		set ::theme_choice $name
		apply_theme [dict get $resp result]
		prefs_save
	} else {
		# Failed: the Preferences button must name the theme still applied.
		set ::theme_choice $::theme_name
		report_error "Theme '$name': [dict get $resp error message]" \
			[dict get $resp error code]
	}
}

# The themes the core can load, as picker rows {name label}; installed ones
# included (D39). A core without theme.list: the shipped four.
proc theme_pick_rows {} {
	set names {default solarized-dark solarized-light acme}
	set resp [rio_call theme.list {}]
	if {[dict get $resp ok]} { set names [dict get $resp result themes] }
	set rows {}
	foreach name $names { lappend rows [list $name [theme_label $name]] }
	return $rows
}

# View ▸ Theme… (D92): a bounded picker, opened on the theme in use.
proc theme_pick_dialog {} {
	set name [pick_dialog "Theme" [theme_pick_rows] $::theme_name]
	if {$name ne "" && $name ne $::theme_name} { do_theme $name }
}

# A theme's label, from its file name: "solarized-dark" -> "Solarized Dark".
proc theme_label {name} {
	set words {}
	foreach w [split $name -] { lappend words [string totitle $w] }
	return [join $words " "]
}
