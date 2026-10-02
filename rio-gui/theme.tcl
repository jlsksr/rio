# rio-gui/theme.tcl — the theme applier and the editor font.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# Editor-font picker (D56). A themed modal like the others: a family list (every
# monospaced-or-not family the system reports, de-duplicated), a size spinner, and a
# live preview in the chosen font. OK pins the choice as the override; "Use Theme
# Font" clears it so the document view follows the theme again. Seeded from the
# current effective font (override if set, else the theme's).
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
	# The family to pre-select: the user's override if any, else the CONCRETE family the
	# editor is wearing. The theme records a logical alias (`monospace`) that `font
	# families` never lists, so matching that against the listbox found nothing and left
	# the current font unmarked — `font actual` resolves the alias to the real family.
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

# OK: pin the picked family and size as the persisted override, apply live.
proc editor_font_apply_dialog {w} {
	set sel [$w.body.fam.list curselection]
	if {$sel ne ""} { set ::editor_font_family [$w.body.fam.list get $sel] }
	set sz $::efont_size
	if {[string is integer -strict $sz] && $sz >= 5 && $sz <= 72} { set ::editor_font_size $sz }
	destroy $w
	apply_editor_font
	prefs_save
}

# "Use Theme Font": clear both overrides so the document view follows the theme again.
proc editor_font_reset_dialog {w} {
	set ::editor_font_family ""
	set ::editor_font_size 0
	destroy $w
	apply_editor_font
	prefs_save
}

# ---------------------------------------------------------------------------
# Theme applier (D24). The core serves the theme as a role table
# (theme.get); here we map roles onto Tk. NAMED fonts are referenced by name by
# every widget, so reconfiguring one updates them all live; explicit per-widget
# config makes a colour switch live too (the option DB only reaches widgets
# created afterwards). Keeping this Tk mapping here is what lets theme files stay
# dumb data.
# ---------------------------------------------------------------------------
set ::theme_colors {} ;# active colour roles, consulted by refresh_tabs

# Editor font override (D56). RioEditorFont is the theme's named font; the user may
# override its family and/or size (a picked font, or a zoom step). We overlay the
# override onto the theme's own values (editor_theme_*, recorded by apply_theme) and
# reconfigure the one named font — every editor widget references it by name, so the
# change is live everywhere at once. Then repaint the per-group chrome whose geometry
# tracks the font: the gutter width/numbers and the wrap-indent margins both scale
# with the glyph width. A no-op before the first apply_theme created the font.
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

# The current effective editor size in points — the override if set, else the theme's.
proc editor_font_size_now {} {
	return [expr {$::editor_font_size > 0 ? $::editor_font_size : $::editor_theme_size}]
}

# Zoom the document view by `delta` points (Ctrl+scroll, Ctrl+ +/-). This pins an
# ABSOLUTE size override, clamped to a sane range, so the choice survives a theme
# switch — the user's explicit zoom outranks the theme until they reset it (Ctrl+0).
proc editor_zoom {delta} {
	set sz [expr {[editor_font_size_now] + $delta}]
	if {$sz < 5}  { set sz 5 }
	if {$sz > 72} { set sz 72 }
	if {$sz == [editor_font_size_now] && $::editor_font_size > 0} return
	set ::editor_font_size $sz
	apply_editor_font
	prefs_save
}

# Drop the size override and fall back to the active theme's editor size (Ctrl+0). The
# family override, if any, is left in place — reset zoom means size, not font choice.
proc editor_zoom_reset {} {
	if {$::editor_font_size == 0} return
	set ::editor_font_size 0
	apply_editor_font
	prefs_save
}

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

# Apply the active theme's colours/fonts to one editor group: its text surface,
# scrollbar-corner frame, tab strip, and the D32 syntax tags. Shared by apply_theme
# (all groups on a theme switch) and add_group (a freshly-split group). Reads the
# role table from ::theme_colors, which apply_theme sets before calling this.
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
	# The find bar's match paint (D36); the selection stays on top so the
	# current match reads over the findmatch band.
	set fm [expr {[dict exists $c editor.findmatch] \
		? [dict get $c editor.findmatch] : [dict get $c editor.selection]}]
	$t tag configure findmatch -background $fm
	# Column/block editing (D40): a width selection reuses the selection colour. The
	# zero-width caret column is drawn as placed blinking bars (col_bars_draw), not a
	# tag, so it needs no tag config here. Raised above the syntax colours.
	$t tag configure coltag -background [dict get $c editor.selection]
	# Caret-line band (D60): the editor.currentline role, or a faint blend of the surface
	# toward the foreground for a theme predating it. Lowered to the bottom so syntax text
	# (fg only) reads over it and selection / find bands paint above it.
	set cl [expr {[dict exists $c editor.currentline] \
		? [dict get $c editor.currentline] \
		: [blend_hex [dict get $c editor.bg] [dict get $c editor.fg] 8]}]
	$t tag configure curline -background $cl
	$t tag lower curline
	$t tag raise sel
	$t tag raise coltag
}

proc apply_theme {theme} {
	set c [dict get $theme colors]
	set ::theme_colors $c
	set ::aqua_appearance [aqua_appearance_for [dict get $c ui.bg]]
	aqua_appearance_all   ;# D135: native controls follow the theme's lightness (Aqua only)
	ensure_fonts [dict get $theme fonts]
	# Record the theme's own editor font, then overlay the user's font override (D56)
	# back on top of it — otherwise a theme switch would silently discard a picked font
	# or an active zoom. apply_editor_font reconfigures RioEditorFont before the restyle
	# loop below measures it for the gutter and wrap-indent geometry.
	set _ef [dict get $theme fonts RioEditorFont]
	set ::editor_theme_family [dict get $_ef family]
	set ::editor_theme_size   [dict get $_ef size]
	apply_editor_font
	# Editor surface — every group's widget, frame, tab strip, and syntax tags (D33).
	# Reconfiguring here recolours existing highlighting live on a theme switch; the
	# highlight passes raise the sel tag so a selection stays legible over the colours.
	foreach _g $::groups { restyle_group $_g }
	# Chrome: status bar + dock divider. The tab strips live inside each group and are
	# recoloured by refresh_tabs (called at the end of apply_theme).
	.status configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.sash configure -background [dict get $c tab.bar.bg]   ;# the dock divider/grip
	.bsash configure -background [dict get $c tab.bar.bg]  ;# the bottom-dock height grip
	# The dock sites + the file/git panes: reuse the UI role (no dedicated sidebar
	# role yet); list selections borrow the editor's selection colour so the panes
	# match the surface. Each site's tab strip is coloured by restyle_tabs (below).
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
	# The rich-list panes (D42/D43): a white content "well" (editor surface) with a
	# full-width selection band (the editor selection colour jka already likes) and a
	# subtler hover band blended toward it. selrow raised above hoverrow so the
	# selection wins under the pointer. The file and git lists share this chrome.
	set fbg [dict get $c editor.bg]
	foreach well {.pfiles.well .pgit.well} {
		$well configure -background $fbg
		set body $well.body
		$body configure -font RioUIFont -background $fbg -foreground [dict get $c ui.fg]
		$body tag configure selrow   -background [dict get $c editor.selection]
		$body tag configure hoverrow -background [blend_hex $fbg [dict get $c editor.selection] 25]
		$body tag raise selrow
	}
	# The navigator's glyph + git-flag colours (D43): navicon tints the type glyph a
	# muted foreground; the flag letters borrow the diff/accent roles by kind (added
	# green, deleted red, modified accent) and the dir rollup dot a muted accent.
	.pfiles.well.body tag configure navicon  -foreground [blend_hex [dict get $c ui.fg] $fbg 35]
	.pfiles.well.body tag configure navadd   -foreground [dict get $c diff.added]
	.pfiles.well.body tag configure navdel   -foreground [dict get $c diff.removed]
	.pfiles.well.body tag configure navmod   -foreground [dict get $c accent]
	.pfiles.well.body tag configure navdirty -foreground [blend_hex [dict get $c accent] $fbg 40]
	# The git list's two status chars share the same kind->colour mapping.
	.pgit.well.body tag configure gitadd -foreground [dict get $c diff.added]
	.pgit.well.body tag configure gitdel -foreground [dict get $c diff.removed]
	.pgit.well.body tag configure gitmod -foreground [dict get $c accent]
	# The diff area is code, so it takes the editor surface.
	.pgit.diff configure -font RioEditorFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg]
	# The commit bar (D45): UI chrome like the header; the summary entry on the editor
	# surface like the find entry so it reads as a place to type.
	.pgit.commit configure -background [dict get $c ui.bg]
	.pgit.commit.go configure -font RioUIFont
	.pgit.commit.msg configure -font RioUIFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor]
	# The placeholder hint: on the entry surface, in a muted grey blended toward it.
	.pgit.commit.msg.ph configure -font RioUIFont \
		-background [dict get $c editor.bg] \
		-foreground [blend_hex [dict get $c editor.fg] [dict get $c editor.bg] 50]
	# The ＋ toggle is chrome; the description body reads like the summary (editor surface),
	# with its own placeholder muted the same way.
	.pgit.commit.more configure -font RioUIFont
	.pgit.commit.body configure -font RioUIFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor]
	.pgit.commit.body.ph configure -font RioUIFont \
		-background [dict get $c editor.bg] \
		-foreground [blend_hex [dict get $c editor.fg] [dict get $c editor.bg] 50]
	# The agent chat pane (D26): the chat.* roles + RioChatFont; accent on labels.
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
	# The bottom strip: the agent selector is a CONTROL, so it takes the accent the
	# pane's other controls take (D68 — static text is muted, interactive text is not),
	# while the working indicator beside it stays quiet chrome.
	.chat.status configure -background [dict get $c tab.bar.bg]
	.chat.status.sel configure -font RioUIFont \
		-background [dict get $c tab.bar.bg] -foreground [dict get $c accent]
	.chat.status.sel.m configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.chat.status.busy configure -font RioUIFont \
		-background [dict get $c tab.bar.bg] -foreground [dict get $c ui.fg]
	# Speaker headers get a full-width highlight band so each turn is easy to find in
	# the log (diffs, tool lines, replies). The label's trailing newline is in the tag
	# range, so the background fills to the right edge. Two tints keep You vs Agent apart.
	.chat.log tag configure agent-label -font RioUIFont -foreground [dict get $c accent] \
		-background [dict get $c ui.bg] -spacing1 4 -spacing3 2
	.chat.log tag configure you-label   -font RioUIFont -foreground [dict get $c chat.fg] \
		-background [dict get $c editor.selection] -spacing1 4 -spacing3 2
	.chat.log tag configure error-label -font RioUIFont -foreground [dict get $c error]
	.chat.log tag configure tool        -font RioUIFont -foreground [dict get $c gutter.fg]
	.chat.log tag configure tool-error  -font RioUIFont -foreground [dict get $c error]
	# Reasoning reads as an aside: the muted colour the tool lines already use, plus an
	# indent that survives wrapping, so a long think is visibly not the answer. No new
	# theme role — a theme that styles the tool lines styles this with them.
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
	# The find/replace bar (D36): UI chrome, entries on the editor surface.
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
	# The Search panel (D52): chrome like the find bar, the query entry on the editor
	# surface (a place to type), the well + rich-list like the dock panes. The
	# file/buffer-header rows take the accent; the match rows the editor foreground.
	foreach w {.results .results.hdr .results.rep} { $w configure -background [dict get $c ui.bg] }
	foreach w {.results.hdr.l .results.hdr.count .results.hdr.close .results.hdr.case .results.hdr.word .results.hdr.regex .results.rep.l} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	.results.rep.all configure -font RioUIFont
	foreach w {.results.hdr.case .results.hdr.word .results.hdr.regex} {
		$w configure -activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
	}
	# The scope option menu (menubutton + its dropdown) takes the UI chrome.
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
	# The per-match band: the theme's diff-added green (light green on light themes,
	# a dark green on dark ones — always readable under editor.fg, D51). Raised above
	# the selection band so a hit stays visible on the selected row.
	$rbody tag configure fimatch -background [dict get $c diff.added.bg]
	$rbody tag raise selrow
	$rbody tag raise fimatch
	# The compare/diff view (D28): the panes take the editor surface, the headers the
	# UI chrome (like the dock); row tags tint removed/added lines and grey the
	# fillers so a changed line reads as a coloured band (VSCode-style).
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
	# Named-font defaults for widgets created later (dialogs, the future chat pane).
	option add *Text.font RioEditorFont
	option add *Label.font RioUIFont
	if {[dict size $::buffers]} refresh_tabs
	aqua_native_colours_all   ;# D135: leave native buttons to the appearance (Aqua only)
}

# Switch themes live (View menu): re-fetch from the core and re-apply.
proc do_theme {name} {
	set resp [rio_call theme.get [dict create name $name]]
	if {[dict get $resp ok]} {
		set ::theme_name $name
		set ::theme_choice $name
		apply_theme [dict get $resp result]
		prefs_save
	} else {
		# The switch failed, so snap the tracked choice back to the theme still
		# applied — it drives the Preferences button's label, which must never
		# claim a theme the editor isn't wearing.
		set ::theme_choice $::theme_name
		report_error "Theme '$name': [dict get $resp error message]" \
			[dict get $resp error code]
	}
}

# The themes the core can load, as picker rows {name label} — so a theme installed from
# a repository (D39) appears with no wiring of its own. Built on demand rather than
# cached into a widget: this is the only reader, and an install/removal is then live
# with nothing to refill. An older remote core without theme.list keeps the shipped four.
proc theme_pick_rows {} {
	set names {default solarized-dark solarized-light acme}
	set resp [rio_call theme.list {}]
	if {[dict get $resp ok]} { set names [dict get $resp result themes] }
	set rows {}
	foreach name $names { lappend rows [list $name [theme_label $name]] }
	return $rows
}

# View ▸ Theme… and the Preferences ▸ View theme button (D92): pick a theme from the
# bounded list instead of a cascade that grows with every installed theme. This was the
# last data-driven, unbounded menu in rio — the standing X11 over-tall-menu caveat — and
# it retires the same way the Tabs cascade did in D74, through pick_dialog. Opening on
# the theme in use makes the dialog show the current value, the job the cascade's radio
# checkmark used to do.
proc theme_pick_dialog {} {
	set name [pick_dialog "Theme" [theme_pick_rows] $::theme_name]
	if {$name ne "" && $name ne $::theme_name} { do_theme $name }
}

# "solarized-dark" -> "Solarized Dark": menu labels derive from theme file names.
proc theme_label {name} {
	set words {}
	foreach w [split $name -] { lappend words [string totitle $w] }
	return [join $words " "]
}
