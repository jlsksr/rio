#!/usr/bin/env wish
#
# Headless test for the remote file browser (AGENTS.md D29/D30). remote_browse_dialog
# is what replaces the native tk_get*File choosers when the core is remote: it walks
# the CORE's filesystem over fs.list — the same op the docked file pane uses — so Open
# / Save As / Open Folder point-and-click on the server's disk instead of the client's.
#
# The browser's ops are transport-agnostic (the D30 point: local and remote run the
# same code), so we exercise them against the DEFAULT spawned local core over a real
# fs.list round-trip, against a known temp tree. The navigation/choose logic runs
# against a widget skeleton (deterministic, no modal event loop); one end-to-end pass
# drives the real modal to prove it builds and tears down. Needs a DISPLAY (Tk).
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/browse.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding (cp1252 on Windows), so this
# file's own non-ASCII expectations arrive mojibake and fail against the correctly-
# decoded values the GUI produces. The same guard the rio-gui and server entry points
# carry -- a test file is an entry point too. No-op where the system encoding is UTF-8.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
set ::env(RIO_GUI_HEADLESS) 1
set argv {}                          ;# no --connect ⇒ default: spawn a local core
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs/workspace (D31)
source [file join [file dirname [info script]] .. rio-gui.tcl]

proc report_error {msg {code ""}} { set ::last_error $msg }

set ::fails 0
proc ok {label got want} {
	if {$got eq $want} { puts "PASS  $label" } else {
		puts "FAIL  $label\n        got:  $got\n        want: $want" ; incr ::fails
	}
}
proc spit {path s} { set f [open $path w] ; puts -nonewline $f $s ; close $f }
# The row index in ::rbrowse_rows whose abspath ends in $tail, or -1.
proc row_index {tail} {
	set i 0
	foreach row $::rbrowse_rows {
		if {[file tail [lindex $row 1]] eq $tail} { return $i }
		incr i
	}
	return -1
}
# A minimal .rbrowse skeleton: exactly the widgets rbrowse_go/activate/choose touch,
# without remote_browse_dialog's modal tkwait — so navigation is testable in-line.
proc skeleton {mode} {
	catch {destroy .rbrowse}
	toplevel .rbrowse
	entry .rbrowse.loc
	frame .rbrowse.body
	listbox .rbrowse.body.list -exportselection 0
	entry .rbrowse.name
	set ::rbrowse_mode   $mode
	set ::rbrowse_result ""
	set ::rbrowse_rows   {}
}

# --- a known temp tree on the core's (== our) filesystem ---------------------
set td [file tempfile tmpf] ; close $td ; file delete $tmpf
set T [file normalize $tmpf.d]
file mkdir [file join $T sub1] [file join $T sub2]
spit [file join $T a.txt] "aaa"
spit [file join $T b.txt] "bbb"
spit [file join $T sub1 deep.txt] "deep"

# --- unit: rbrowse_rows_for (the remote fs.list walk) ------------------------
set info [rbrowse_rows_for $T]
ok "rows: ok"            [dict get $info ok]  1
ok "rows: dir echoed"    [dict get $info dir] $T
set rows [dict get $info rows]
# Order: "../", then dirs (dict-sorted), then files (dict-sorted).
ok "rows: parent first"  [lindex [lindex $rows 0] 2] "../"
ok "rows: parent path"   [lindex [lindex $rows 0] 1] [file dirname $T]
ok "rows: dirs then files" [lmap r $rows {lindex $r 2}] \
	[list "../" "sub1/" "sub2/" "  a.txt" "  b.txt"]
ok "rows: a.txt abspath"  [lindex [lindex $rows 3] 1] [file join $T a.txt]
# At the filesystem root there is no synthetic parent row. Ask the platform for its
# root rather than hardcoding "/": on Windows that is "C:/", and "/" is not even an
# absolute path there (file pathtype calls it "volumerelative"), so the core refused
# to list it and this aborted the whole suite.
set ::fsroot [file normalize /]
set rootinfo [rbrowse_rows_for $::fsroot]
ok "rows: root listed"     [dict get $rootinfo ok] 1
ok "rows: root has no parent" [expr {[lindex [lindex [dict get $rootinfo rows] 0] 2] ne "../"}] 1

# --- unit: rbrowse_start (where the browser opens) ---------------------------
ok "start: file seed -> its dir" [rbrowse_start [file join $T a.txt]] $T
ok "start: no anchor -> /"       [rbrowse_start ""] /
open_folder $T
ok "start: project open -> root" [rbrowse_start ""] $T

# --- navigation + choose, driven through the widget skeleton -----------------
# OPEN mode: files are listed; picking a file yields its path.
skeleton open
rbrowse_go $T
ok "open: dir set"        $::rbrowse_dir $T
ok "open: location shown" [.rbrowse.loc get] $T
ok "open: file listed"    [expr {[row_index a.txt] >= 0}] 1
.rbrowse.body.list selection set [row_index a.txt]
rbrowse_choose
ok "open: choose a file"  $::rbrowse_result [file join $T a.txt]
# Choosing a directory row in open mode is refused (must be a file).
skeleton open
rbrowse_go $T
.rbrowse.body.list selection set [row_index sub1]
rbrowse_choose
ok "open: refuse a dir"   $::rbrowse_result ""
# Activating a directory row descends into it.
rbrowse_activate
ok "open: descend"        $::rbrowse_dir [file join $T sub1]
ok "open: deep listed"    [expr {[row_index deep.txt] >= 0}] 1

# DIR mode: files are hidden; choose returns the shown directory.
skeleton dir
rbrowse_go $T
ok "dir: files hidden"    [row_index a.txt] -1
ok "dir: only dirs+parent" [.rbrowse.body.list size] 3
rbrowse_choose
ok "dir: choose the dir"  $::rbrowse_result $T

# SAVE mode: a typed Name joins the shown directory; a file row fills the Name.
skeleton save
rbrowse_go $T
.rbrowse.name insert end "new.txt"
rbrowse_choose
ok "save: dir + name"     $::rbrowse_result [file join $T new.txt]
skeleton save
rbrowse_go $T
.rbrowse.body.list selection set [row_index b.txt]
rbrowse_activate
ok "save: file fills name" [.rbrowse.name get] "b.txt"

# --- integration: the real modal builds, then Cancel tears it down -----------
proc _cancel_when_up {} {
	if {[winfo exists .rbrowse]} { destroy .rbrowse ; return }
	after 20 _cancel_when_up
}
after 20 _cancel_when_up
set r [remote_browse_dialog "smoke" open $T]
ok "modal: cancel returns empty" $r ""
ok "modal: window gone"          [winfo exists .rbrowse] 0

# --- cleanup -----------------------------------------------------------------
file delete -force $T

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
