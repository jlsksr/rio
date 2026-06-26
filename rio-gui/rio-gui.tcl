#!/usr/bin/env wish
#
# rio-gui — the Tk frontend (AGENTS.md D1). A *thin view* (D3): it never edits
# its own text widget. Keystrokes become buffer.replace requests; the widget only
# changes when the core echoes a buffer.changed event back. Open/save go through
# the fs.* ops, undo/redo through edit.*, and buffers (tabs) through buffer.new /
# buffer.close. The core is embedded IN-PROCESS (D2's default transport):
# rio::core::call runs a request and returns the response plus any events
# synchronously — so there is no round-trip lag, and the only way text appears on
# screen is the core's own change event.
#
# Multi-buffer: the core owns the buffers (D3); the frontend keeps the per-buffer
# *view* state — tab order, which one is active, and each buffer's cursor/viewport
# (frontend-local per D22). One text widget shows the active buffer; switching
# tabs swaps its contents and restores that buffer's cursor.
#
# The view stays dumb robustly by RENAMING the real text-widget command and
# proxying it: Tk's class bindings still call `.t insert`/`.t delete`, the proxy
# turns those into protocol requests and suppresses the local edit. The character
# arrives as a proper Tcl argument, so every key — brackets, quotes, backslashes,
# braces — is handled identically, and paste/cut come along for free.
#
# Run:  wish rio-gui.tcl [file ...]

package require Tk
package require json

# Embed the core (Tk-free; we are the only Tk in this process).
source [file join [file dirname [info script]] .. rio-core core.tcl]

# Per-buffer view state. The core holds the text; we hold the rest.
set ::buffers {} ;# id -> {path <s> meta <dict> modified <0|1> cursor <idx> yview <frac>}
set ::order   {} ;# buffer ids, in tab order
set ::cur     "" ;# active buffer id

proc bufget {id key} { dict get $::buffers $id $key }
proc bufset {id key val} { dict set ::buffers $id $key $val }

# ---------------------------------------------------------------------------
# Core calls: run the op, apply any buffer.changed events to the widget, and
# hand the response back. This is the single seam to the core.
# ---------------------------------------------------------------------------
proc rio_call {op params} {
	set r [rio::core::call $op $params]
	foreach ev [dict get $r events] {
		switch -- [dict get $ev event] {
			buffer.changed  { apply_change [dict get $ev params] }
			project.opened  { on_project_opened [dict get $ev params] }
		}
	}
	return [dict get $r response]
}

# Surface a core error to the user (the {code, message} taxonomy, AGENTS.md O2).
# One seam, so every failed op shows a dialog instead of crashing a caller that
# assumed success — and the headless smoke can override it to capture errors
# without a modal blocking the run.
proc report_error {message {code ""}} {
	tk_messageBox -icon error -type ok -title rio \
		-message [expr {$code eq "" ? $message : "$message  ($code)"}]
}

# Run an op that is expected to succeed and return its result, or "" after
# surfacing the error. For the internal "can't fail in normal use" calls (new,
# undo/redo): a vanished buffer or a bug becomes a dialog, not a missing-`result`
# crash. do_open/do_save inspect `ok` themselves — they have real recovery. (None
# of these ops returns an empty result on success, so "" is an unambiguous fail.)
proc rio_result {op params} {
	set resp [rio_call $op $params]
	if {[dict get $resp ok]} { return [dict get $resp result] }
	set e [dict get $resp error]
	report_error [dict get $e message] [dict get $e code]
	return ""
}

# Apply a change through the REAL widget command (bypassing the proxy). .t
# replace takes line.col indices directly — the payoff of D12 sharing the Tk
# text-widget index format: the view layer is nearly free.
proc apply_change {p} {
	::rio_real_t replace [dict get $p start] [dict get $p end] [dict get $p text]
	::rio_real_t see insert
}

# Load the active buffer's canonical text into the widget (on switch / open).
proc load_buffer {} {
	set resp [rio_call buffer.text [dict create buffer $::cur]]
	::rio_real_t delete 1.0 end
	if {[dict get $resp ok]} {
		::rio_real_t insert 1.0 [dict get $resp result text]
	} else {
		set e [dict get $resp error]
		report_error [dict get $e message] [dict get $e code]
	}
}

# ---------------------------------------------------------------------------
# Buffer / tab bookkeeping.
# ---------------------------------------------------------------------------
proc register_buffer {id path meta} {
	dict set ::buffers $id \
		[dict create path $path meta $meta modified 0 cursor 1.0 yview 0.0]
	lappend ::order $id
}

# Make `id` the active buffer: stash the outgoing buffer's cursor/viewport, swap
# the widget to `id`, and restore its cursor/viewport.
proc activate {id} {
	if {$::cur ne "" && [dict exists $::buffers $::cur]} {
		bufset $::cur cursor [::rio_real_t index insert]
		bufset $::cur yview  [lindex [::rio_real_t yview] 0]
	}
	set ::cur $id
	load_buffer
	catch {::rio_real_t mark set insert [bufget $id cursor]}
	catch {::rio_real_t yview moveto    [bufget $id yview]}
	::rio_real_t see insert
	focus .t
	refresh_all
}

proc close_buffer {id} {
	rio_call buffer.close [dict create buffer $id]
	set ::buffers [dict remove $::buffers $id]
	set ::order [lsearch -all -inline -not -exact $::order $id]
}

# Drop a leftover empty, unsaved, untitled scratch buffer (so opening a file from
# a fresh launch reuses the slot instead of leaving a blank tab behind). Refresh
# the chrome if we dropped anything: close_buffer mutates ::order but doesn't
# redraw, so a pruned tab would otherwise linger on screen, orphaned.
proc prune_scratch {keep} {
	set pruned 0
	foreach id $::order {
		if {$id eq $keep} continue
		if {[bufget $id path] eq "" && ![bufget $id modified] && [rio::doc::text $id] eq ""} {
			close_buffer $id
			set pruned 1
		}
	}
	if {$pruned} refresh_all
}

# ---------------------------------------------------------------------------
# Actions. The do_* procs take explicit arguments (no dialogs) so they are
# scriptable and testable; the *_dialog wrappers add the file choosers.
# ---------------------------------------------------------------------------
proc do_new {} {
	set res [rio_result buffer.new {}]
	if {$res eq ""} return
	set id [dict get $res buffer]
	register_buffer $id "" {}
	activate $id
}

proc do_open {path} {
	# Already open? Just switch to its tab.
	foreach id $::order {
		if {$path ne "" && [bufget $id path] eq $path} { activate $id ; return 1 }
	}
	set resp [rio_call file.open [dict create path $path]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not open $path:\n[dict get $resp error message]"
		return 0
	}
	set res [dict get $resp result]
	set id  [dict get $res buffer]
	register_buffer $id $path \
		[dict create encoding [dict get $res encoding] eol [dict get $res eol]]
	activate $id
	prune_scratch $id
	if {[dict get $res mixed]} {
		tk_messageBox -icon info -type ok -title rio \
			-message "Mixed line endings; the file will be saved as [dict get $res eol]."
	}
	return 1
}

# ---------------------------------------------------------------------------
# The file pane (AGENTS.md: the file-tree pane; D9 a later reflow concern). A
# lazy directory navigator over the core's project root: it lists ONE directory
# per fs.list call and descends on demand, rather than the core walking a whole
# repo. The core owns "which folder is open" (project.*); this pane is a dumb
# view of it — opening a folder goes through project.open and the pane repaints
# from the project.opened event (D3), the same event-driven path as buffer edits.
# ::nav_dir is the directory currently shown (absolute); ::nav_rows is a parallel
# list mapping each listbox row to {type abspath} so a click knows what it hit.
# ---------------------------------------------------------------------------
proc open_folder {path} {
	set resp [rio_call project.open [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error "Could not open folder $path:\n[dict get $resp error message]" \
			[dict get $resp error code]
		return 0
	}
	return 1   ;# the pane repaints via the project.opened event (on_project_opened)
}

proc on_project_opened {p} {
	set ::nav_dir [dict get $p root]
	populate_nav
}

# Repaint the pane with the entries of ::nav_dir: a ".." row (unless at the root),
# then directories, then files — each group dictionary-sorted by the core already.
proc populate_nav {} {
	.side.list delete 0 end
	set ::nav_rows {}
	if {$::nav_dir eq ""} {
		.side.head configure -text "(no folder)"
		.side.list insert end "  Open a folder…"
		lappend ::nav_rows [list none ""]
		return
	}
	set root [dict get [rio_call project.get {}] result root]
	.side.head configure -text [nav_header $::nav_dir $root]
	if {$::nav_dir ne $root} {
		.side.list insert end "../"
		lappend ::nav_rows [list dir [file dirname $::nav_dir]]
	}
	set resp [rio_call fs.list [dict create path $::nav_dir]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	set entries [dict get $resp result entries]
	foreach grp {dir file} {
		foreach e $entries {
			if {[dict get $e type] ne $grp} continue
			set name [dict get $e name]
			.side.list insert end [expr {$grp eq "dir" ? "$name/" : "  $name"}]
			lappend ::nav_rows [list $grp [file join $::nav_dir $name]]
		}
	}
}

# Header: the project name, plus the path from the root when in a subdirectory.
proc nav_header {dir root} {
	if {$dir eq $root} { return [file tail $root] }
	return "[file tail $root]/[string range $dir [expr {[string length $root] + 1}] end]"
}

# Double-click / Enter on a row: descend into a directory, or open a file in a tab.
proc nav_activate {} {
	set sel [.side.list curselection]
	if {$sel eq ""} return
	lassign [lindex $::nav_rows $sel] type path
	switch -- $type {
		dir  { set ::nav_dir $path ; populate_nav }
		file { do_open $path }
	}
}

proc open_folder_dialog {} {
	set p [tk_chooseDirectory -title "Open folder"]
	if {$p ne ""} { open_folder $p }
}

proc do_save_as {path} {
	set resp [rio_call file.save [dict create buffer $::cur path $path]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not save $path:\n[dict get $resp error message]"
		return 0
	}
	bufset $::cur path $path
	clear_modified
	return 1
}

proc do_save {} {
	if {[bufget $::cur path] eq ""} { return [save_as_dialog] }
	set resp [rio_call file.save [dict create buffer $::cur]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not save:\n[dict get $resp error message]"
		return 0
	}
	clear_modified
	return 1
}

proc do_undo {} {
	set res [rio_result edit.undo [dict create buffer $::cur]]
	if {$res ne "" && [dict get $res changed]} { mark_modified 1 }
}
proc do_redo {} {
	set res [rio_result edit.redo [dict create buffer $::cur]]
	if {$res ne "" && [dict get $res changed]} { mark_modified 1 }
}

# Close the active buffer; guard unsaved changes, and keep at least one tab.
proc do_close {} {
	if {![maybe_discard]} return
	set victim $::cur
	set idx [lsearch -exact $::order $victim]
	close_buffer $victim
	if {![llength $::order]} {
		do_new
	} else {
		set ni [expr {$idx >= [llength $::order] ? [llength $::order] - 1 : $idx}]
		activate [lindex $::order $ni]
	}
}
# Close any tab (the × button): focus it first so a discard prompt is in context.
proc close_tab {id} { activate $id ; do_close }

proc cycle {dir} {
	if {[llength $::order] < 2} return
	set i [lsearch -exact $::order $::cur]
	activate [lindex $::order [expr {($i + $dir) % [llength $::order]}]]
}

# --- dialog wrappers ---------------------------------------------------------
proc open_dialog {} {
	set p [tk_getOpenFile -title "Open file"]
	if {$p ne ""} { do_open $p }
}
proc save_as_dialog {} {
	set p [tk_getSaveFile -title "Save as"]
	if {$p eq ""} { return 0 }
	return [do_save_as $p]
}
# Returns 1 if it is safe to throw away the active buffer.
proc maybe_discard {} {
	if {![bufget $::cur modified]} { return 1 }
	switch -- [tk_messageBox -icon question -type yesnocancel -title rio \
			-message "Discard unsaved changes to [tab_name $::cur]?"] {
		yes    { return 1 }
		no     { return [do_save] }
		cancel { return 0 }
	}
}
proc do_quit {} {
	foreach id $::order {
		if {[bufget $id modified]} {
			activate $id
			if {![maybe_discard]} return
		}
	}
	exit 0
}

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

proc tab_name {id} {
	set p [bufget $id path]
	set n [expr {$p eq "" ? "untitled" : [file tail $p]}]
	return "$n[expr {[bufget $id modified] ? { *} : {}}]"
}
proc refresh_all   {} { refresh_tabs ; refresh_title ; refresh_status }
proc refresh_title {} { wm title . "rio — [tab_name $::cur]" }
proc refresh_status {} {
	set p    [bufget $::cur path]
	set name [expr {$p eq "" ? "untitled" : $p}]
	set meta [bufget $::cur meta]
	set enc  [expr {[dict exists $meta encoding] ? [dict get $meta encoding] : "utf-8"}]
	set eol  [expr {[dict exists $meta eol] ? [dict get $meta eol] : "lf"}]
	.status configure -text [format "%s      %s  %s%s      %d buffer(s)" \
		$name $enc $eol [expr {[bufget $::cur modified] ? {      modified} : {}}] \
		[llength $::order]]
}
proc refresh_tabs {} {
	set c $::theme_colors
	set fg [dict get $c tab.fg]
	foreach w [winfo children .tabs] { destroy $w }
	foreach id $::order {
		set active [expr {$id eq $::cur}]
		set bg [expr {$active ? [dict get $c tab.active.bg] : [dict get $c tab.inactive.bg]}]
		set f [frame .tabs.b$id -background $bg -borderwidth 1 \
			-relief [expr {$active ? "raised" : "flat"}]]
		label $f.l -text [tab_name $id] -background $bg -foreground $fg \
			-font RioUIFont -padx 6 -pady 1
		label $f.x -text "×" -background $bg -foreground $fg \
			-font RioUIFont -padx 3
		bind $f.l <Button-1> [list activate $id]
		bind $f.x <Button-1> [list close_tab $id]
		pack $f.l -side left ; pack $f.x -side right
		pack $f -side left -padx 1 -pady 1
	}
}

# ---------------------------------------------------------------------------
# Theme applier (AGENTS.md D24). The core serves the theme as a role table
# (theme.get); here we map roles onto Tk. NAMED fonts are referenced by name by
# every widget, so reconfiguring one updates them all live; explicit per-widget
# config makes a colour switch live too (the option DB only reaches widgets
# created afterwards). Keeping this Tk mapping here is what lets theme files stay
# dumb data.
# ---------------------------------------------------------------------------
set ::theme_colors {} ;# active colour roles, consulted by refresh_tabs

proc ensure_fonts {fonts} {
	dict for {name spec} $fonts {
		set opts [list -family [dict get $spec family] -size [dict get $spec size]]
		if {[lsearch -exact [font names] $name] >= 0} {
			font configure $name {*}$opts
		} else {
			font create $name {*}$opts
		}
	}
}

proc apply_theme {theme} {
	set c [dict get $theme colors]
	set ::theme_colors $c
	ensure_fonts [dict get $theme fonts]
	# Editor surface.
	::rio_real_t configure -font RioEditorFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor] \
		-selectbackground [dict get $c editor.selection]
	# Chrome: status bar + tab container.
	.status configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.tabs configure -background [dict get $c tab.bar.bg]
	# File pane: reuse the UI role (no dedicated sidebar role yet); the active row
	# borrows the editor's selection colour so the pane matches the surface.
	.side configure -background [dict get $c ui.bg]
	.side.head configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.side.list configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c editor.selection] \
		-selectforeground [dict get $c ui.fg]
	# Named-font defaults for widgets created later (dialogs, the future chat pane).
	option add *Text.font RioEditorFont
	option add *Label.font RioUIFont
	if {[llength $::order]} refresh_tabs
}

# Switch themes live (View menu): re-fetch from the core and re-apply.
proc do_theme {name} {
	set resp [rio_call theme.get [dict create name $name]]
	if {[dict get $resp ok]} {
		apply_theme [dict get $resp result]
	} else {
		report_error "Theme '$name': [dict get $resp error message]" \
			[dict get $resp error code]
	}
}

# ---------------------------------------------------------------------------
# Build the UI. The literal colours/fonts here are just a bootstrap; apply_theme
# (below, fed by the core's theme.get) reconfigures every widget from the role
# table — the default theme reproduces this plain white-bg "90s productivity"
# look (D24), and the View menu switches it live.
# ---------------------------------------------------------------------------
frame .tabs -background "#bbbbbb"
# The file pane (left): a header + a scrollable listbox the navigator fills.
frame .side -background "#dddddd"
label .side.head -anchor w -font {monospace 9} -padx 4 -pady 2 \
	-background "#dddddd" -foreground black
scrollbar .side.sb -command {.side.list yview}
listbox .side.list -width 26 -activestyle none -exportselection 0 \
	-borderwidth 0 -highlightthickness 0 \
	-background "#dddddd" -foreground black \
	-yscrollcommand {.side.sb set}
pack .side.head -side top -fill x
pack .side.sb   -side right -fill y
pack .side.list -side left -fill both -expand 1
bind .side.list <Double-Button-1> nav_activate
bind .side.list <Return>          nav_activate
text .t -wrap none -undo 0 -font {monospace 12} -width 80 -height 28 \
	-background white -foreground black -insertbackground black \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2
label .status -anchor w -font {monospace 9} -padx 4 -pady 1 \
	-background "#dddddd" -foreground black
pack .tabs   -side top -fill x
pack .status -side bottom -fill x
pack .side   -side left -fill y
pack .t      -side left -fill both -expand 1
focus .t

menu .m ; . configure -menu .m
menu .m.file -tearoff 0
.m add cascade -label File -menu .m.file
.m.file add command -label "New"       -accelerator Ctrl+N       -command do_new
.m.file add command -label "Open…"    -accelerator Ctrl+O       -command open_dialog
.m.file add command -label "Open Folder…" -accelerator Ctrl+Shift+O -command open_folder_dialog
.m.file add command -label "Save"      -accelerator Ctrl+S       -command do_save
.m.file add command -label "Save As…" -accelerator Ctrl+Shift+S -command save_as_dialog
.m.file add separator
.m.file add command -label "Close Tab" -accelerator Ctrl+W       -command do_close
.m.file add command -label "Quit"      -accelerator Ctrl+Q       -command do_quit
menu .m.edit -tearoff 0
.m add cascade -label Edit -menu .m.edit
.m.edit add command -label "Undo" -accelerator Ctrl+Z       -command do_undo
.m.edit add command -label "Redo" -accelerator Ctrl+Shift+Z -command do_redo
menu .m.view -tearoff 0
.m add cascade -label View -menu .m.view
.m.view add command -label "Theme: Default"         -command {do_theme default}
.m.view add command -label "Theme: Solarized Dark"  -command {do_theme solarized-dark}
.m.view add command -label "Theme: Solarized Light" -command {do_theme solarized-light}

# Shortcuts bound on the text widget with `break`, so the widget's own class
# bindings (e.g. Tk's built-in Ctrl+O/Ctrl+Z) don't also fire.
bind .t <Control-n>         { do_new ; break }
bind .t <Control-o>         { open_dialog ; break }
bind .t <Control-O>         { open_folder_dialog ; break }
bind .t <Control-s>         { do_save ; break }
bind .t <Control-S>         { save_as_dialog ; break }
bind .t <Control-w>         { do_close ; break }
bind .t <Control-q>         { do_quit ; break }
bind .t <Control-z>         { do_undo ; break }
bind .t <Control-Z>         { do_redo ; break }
bind .t <Control-y>         { do_redo ; break }
bind .t <Control-Tab>       { cycle 1 ; break }
bind .t <Control-Shift-Tab> { cycle -1 ; break }
wm protocol . WM_DELETE_WINDOW do_quit

# --- widget proxy: edits become protocol requests, never local mutations -----
rename .t ::rio_real_t
proc .t {args} {
	switch -- [lindex $args 0] {
		insert {
			# .t insert <index> <chars> ?tagList chars ...?
			set idx   [::rio_real_t index [lindex $args 1]]
			set chars [lindex $args 2]
			if {$chars ne ""} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer $::cur start $idx end $idx text $chars]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		delete {
			# .t delete <index1> ?index2?
			set i1 [::rio_real_t index [lindex $args 1]]
			set i2 [expr {[llength $args] >= 3
				? [::rio_real_t index [lindex $args 2]]
				: [::rio_real_t index "[lindex $args 1]+1c"]}]
			if {[::rio_real_t compare $i1 < $i2]} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer $::cur start $i1 end $i2 text {}]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		default { return [::rio_real_t {*}$args] }
	}
}

# Apply the core's theme (the built-in default) before the first tab is drawn, so
# every widget — and the tab bar refresh_tabs builds — uses the role table.
apply_theme [dict get [rio_call theme.get {}] result]

# Start on the core's default buffer (an empty "untitled" tab), then process the
# command line: a directory argument opens as the project folder, a file opens in
# a tab. The file pane starts empty until a folder is opened.
set ::nav_dir ""
set ::nav_rows {}
register_buffer $::rio::ops::default "" {}
activate $::rio::ops::default
populate_nav
foreach f $argv {
	if {[file isdirectory $f]} { open_folder $f } else { do_open $f }
}

# A test harness sets RIO_GUI_HEADLESS to keep the window off-screen.
if {[info exists ::env(RIO_GUI_HEADLESS)]} { wm withdraw . }
