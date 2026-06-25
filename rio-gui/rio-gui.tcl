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
		if {[dict get $ev event] eq "buffer.changed"} {
			apply_change [dict get $ev params]
		}
	}
	return [dict get $r response]
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
	::rio_real_t insert 1.0 [dict get $resp result text]
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
# a fresh launch reuses the slot instead of leaving a blank tab behind).
proc prune_scratch {keep} {
	foreach id $::order {
		if {$id eq $keep} continue
		if {[bufget $id path] eq "" && ![bufget $id modified] && [rio::doc::text $id] eq ""} {
			close_buffer $id
		}
	}
}

# ---------------------------------------------------------------------------
# Actions. The do_* procs take explicit arguments (no dialogs) so they are
# scriptable and testable; the *_dialog wrappers add the file choosers.
# ---------------------------------------------------------------------------
proc do_new {} {
	set id [dict get [rio_call buffer.new {}] result buffer]
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
			-message "Could not open $path:\n[dict get $resp error]"
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

proc do_save_as {path} {
	set resp [rio_call file.save [dict create buffer $::cur path $path]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not save $path:\n[dict get $resp error]"
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
			-message "Could not save:\n[dict get $resp error]"
		return 0
	}
	clear_modified
	return 1
}

proc do_undo {} {
	if {[dict get [rio_call edit.undo [dict create buffer $::cur]] result changed]} {
		mark_modified 1
	}
}
proc do_redo {} {
	if {[dict get [rio_call edit.redo [dict create buffer $::cur]] result changed]} {
		mark_modified 1
	}
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
	foreach w [winfo children .tabs] { destroy $w }
	foreach id $::order {
		set active [expr {$id eq $::cur}]
		set bg [expr {$active ? "white" : "#cfcfcf"}]
		set f [frame .tabs.b$id -background $bg -borderwidth 1 \
			-relief [expr {$active ? "raised" : "flat"}]]
		label $f.l -text [tab_name $id] -background $bg -foreground black \
			-font {monospace 9} -padx 6 -pady 1
		label $f.x -text "×" -background $bg -foreground "#555" \
			-font {monospace 9} -padx 3
		bind $f.l <Button-1> [list activate $id]
		bind $f.x <Button-1> [list close_tab $id]
		pack $f.l -side left ; pack $f.x -side right
		pack $f -side left -padx 1 -pady 1
	}
}

# ---------------------------------------------------------------------------
# Build the UI. White-on-black monospace default (D24: the "90s productivity"
# look the project likes); a real theme applier comes later.
# ---------------------------------------------------------------------------
frame .tabs -background "#bbbbbb"
text .t -wrap none -undo 0 -font {monospace 12} -width 80 -height 28 \
	-background white -foreground black -insertbackground black \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2
label .status -anchor w -font {monospace 9} -padx 4 -pady 1 \
	-background "#dddddd" -foreground black
pack .tabs   -side top -fill x
pack .status -side bottom -fill x
pack .t      -side top -fill both -expand 1
focus .t

menu .m ; . configure -menu .m
menu .m.file -tearoff 0
.m add cascade -label File -menu .m.file
.m.file add command -label "New"       -accelerator Ctrl+N       -command do_new
.m.file add command -label "Open…"    -accelerator Ctrl+O       -command open_dialog
.m.file add command -label "Save"      -accelerator Ctrl+S       -command do_save
.m.file add command -label "Save As…" -accelerator Ctrl+Shift+S -command save_as_dialog
.m.file add separator
.m.file add command -label "Close Tab" -accelerator Ctrl+W       -command do_close
.m.file add command -label "Quit"      -accelerator Ctrl+Q       -command do_quit
menu .m.edit -tearoff 0
.m add cascade -label Edit -menu .m.edit
.m.edit add command -label "Undo" -accelerator Ctrl+Z       -command do_undo
.m.edit add command -label "Redo" -accelerator Ctrl+Shift+Z -command do_redo

# Shortcuts bound on the text widget with `break`, so the widget's own class
# bindings (e.g. Tk's built-in Ctrl+O/Ctrl+Z) don't also fire.
bind .t <Control-n>         { do_new ; break }
bind .t <Control-o>         { open_dialog ; break }
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

# Start on the core's default buffer (an empty "untitled" tab), then open any
# files named on the command line.
register_buffer $::rio::ops::default "" {}
activate $::rio::ops::default
foreach f $argv { do_open $f }

# A test harness sets RIO_GUI_HEADLESS to keep the window off-screen.
if {[info exists ::env(RIO_GUI_HEADLESS)]} { wm withdraw . }
