#!/usr/bin/env wish
#
# rio-gui — the Tk frontend (AGENTS.md D1). A *thin view* (D3): it never edits
# its own text widget. Keystrokes become buffer.replace requests; the widget only
# changes when the core echoes a buffer.changed event back. Open/save go through
# the fs.* ops; undo/redo through edit.*. The core is embedded IN-PROCESS (D2's
# default transport): rio::core::call runs a request and returns the response
# plus any events synchronously — so there is no round-trip lag, and the only way
# text appears on screen is the core's own change event (the dumb-view rule, made
# honest).
#
# The view stays dumb robustly by RENAMING the real text-widget command and
# proxying it: Tk's class bindings still call `.t insert`/`.t delete`, the proxy
# turns those into protocol requests and suppresses the local edit. The character
# arrives as a proper Tcl argument, so every key — brackets, quotes, backslashes,
# braces — is handled identically, and paste/cut come along for free.
#
# Run:  wish rio-gui.tcl [file]

package require Tk
package require json

# Embed the core (Tk-free; we are the only Tk in this process).
source [file join [file dirname [info script]] .. rio-core core.tcl]

# Current view state — all frontend-local (D22: cursor/selection/viewport and,
# here, the "which buffer am I showing / is it dirty" bookkeeping).
set ::cur      $::rio::ops::default   ;# id of the buffer on screen
set ::path     ""                     ;# its file path ("" = never saved)
set ::meta     {}                     ;# detected encoding/eol, for the status line
set ::modified 0

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

# Replace the whole widget with the buffer's canonical text (on open / attach).
proc load_buffer {} {
	set resp [rio_call buffer.text [dict create buffer $::cur]]
	::rio_real_t delete 1.0 end
	::rio_real_t insert 1.0 [dict get $resp result text]
	::rio_real_t mark set insert 1.0
	::rio_real_t see insert
}

# ---------------------------------------------------------------------------
# Actions. The do_* procs take explicit arguments (no dialogs) so they are
# scriptable and testable; the *_dialog wrappers add the file choosers.
# ---------------------------------------------------------------------------
proc do_open {path} {
	set resp [rio_call file.open [dict create path $path]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not open $path:\n[dict get $resp error]"
		return 0
	}
	set res [dict get $resp result]
	set ::cur  [dict get $res buffer]
	set ::path $path
	set ::meta [dict create encoding [dict get $res encoding] eol [dict get $res eol]]
	load_buffer
	set_modified 0
	if {[dict get $res mixed]} {
		# Surface, don't force (D22): the dominant convention was chosen.
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
	set ::path $path
	set_modified 0
	return 1
}

proc do_save {} {
	if {$::path eq ""} { return [save_as_dialog] }
	set resp [rio_call file.save [dict create buffer $::cur]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not save:\n[dict get $resp error]"
		return 0
	}
	set_modified 0
	return 1
}

proc do_undo {} {
	if {[dict get [rio_call edit.undo [dict create buffer $::cur]] result changed]} {
		set_modified 1
	}
}
proc do_redo {} {
	if {[dict get [rio_call edit.redo [dict create buffer $::cur]] result changed]} {
		set_modified 1
	}
}

# --- dialog wrappers ---------------------------------------------------------
proc open_dialog {} {
	if {![maybe_discard]} return
	set p [tk_getOpenFile -title "Open file"]
	if {$p ne ""} { do_open $p }
}
proc save_as_dialog {} {
	set p [tk_getSaveFile -title "Save as"]
	if {$p eq ""} { return 0 }
	return [do_save_as $p]
}
# Returns 1 if it is safe to throw away the current buffer.
proc maybe_discard {} {
	if {!$::modified} { return 1 }
	set a [tk_messageBox -icon question -type yesnocancel -title rio \
		-message "Discard unsaved changes?"]
	switch -- $a {
		yes    { return 1 }
		no     { return [do_save] }
		cancel { return 0 }
	}
}
proc do_quit {} { if {[maybe_discard]} { exit 0 } }

# ---------------------------------------------------------------------------
# Title + status line.
# ---------------------------------------------------------------------------
proc set_modified {m} { set ::modified $m ; refresh_title ; refresh_status }
proc refresh_title {} {
	set name [expr {$::path eq "" ? "untitled" : [file tail $::path]}]
	wm title . "rio — $name[expr {$::modified ? { *} : {}}]"
}
proc refresh_status {} {
	set name [expr {$::path eq "" ? "untitled" : $::path}]
	set enc  [expr {[dict exists $::meta encoding] ? [dict get $::meta encoding] : "utf-8"}]
	set eol  [expr {[dict exists $::meta eol] ? [dict get $::meta eol] : "lf"}]
	.status configure -text \
		"$name      $enc  $eol[expr {$::modified ? {      modified} : {}}]"
}

# ---------------------------------------------------------------------------
# Build the UI.
# ---------------------------------------------------------------------------
# Defaults that match the "90s productivity software" look the project likes
# (D24): white page, black text, monospace. A real theme applier comes later.
text .t -wrap none -undo 0 -font {monospace 12} -width 80 -height 28 \
	-background white -foreground black -insertbackground black \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2
label .status -anchor w -font {monospace 9} -padx 4 -pady 1 \
	-background "#dddddd" -foreground black
pack .status -side bottom -fill x
pack .t -side top -fill both -expand 1
focus .t

menu .m ; . configure -menu .m
menu .m.file -tearoff 0
.m add cascade -label File -menu .m.file
.m.file add command -label "Open…"    -accelerator Ctrl+O       -command open_dialog
.m.file add command -label "Save"      -accelerator Ctrl+S       -command do_save
.m.file add command -label "Save As…" -accelerator Ctrl+Shift+S -command save_as_dialog
.m.file add separator
.m.file add command -label "Quit"      -accelerator Ctrl+Q       -command do_quit
menu .m.edit -tearoff 0
.m add cascade -label Edit -menu .m.edit
.m.edit add command -label "Undo" -accelerator Ctrl+Z       -command do_undo
.m.edit add command -label "Redo" -accelerator Ctrl+Shift+Z -command do_redo

# Shortcuts bound on the text widget with `break`, so the widget's own class
# bindings (e.g. Tk's built-in Ctrl+O/Ctrl+Z) don't also fire.
bind .t <Control-o> { open_dialog ; break }
bind .t <Control-s> { do_save ; break }
bind .t <Control-S> { save_as_dialog ; break }
bind .t <Control-q> { do_quit ; break }
bind .t <Control-z> { do_undo ; break }
bind .t <Control-Z> { do_redo ; break }
bind .t <Control-y> { do_redo ; break }
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
					set_modified 1
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
					set_modified 1
				}
			}
			return ""
		}
		default { return [::rio_real_t {*}$args] }
	}
}

# Show whatever the starting buffer holds (empty "untitled", or a file given on
# the command line), then settle the title/status.
if {[llength $argv]} {
	do_open [lindex $argv 0]
} else {
	load_buffer
	set_modified 0
}

# A test harness sets RIO_GUI_HEADLESS to keep the window off-screen.
if {[info exists ::env(RIO_GUI_HEADLESS)]} { wm withdraw . }
