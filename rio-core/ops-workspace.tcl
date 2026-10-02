# rio-core — the workspace.* op namespace (D31).
#
# Save and restore which files were open, per project (rio::workspace). The
# key is the open project's root; the frontend never names it. Without a
# project it is the anonymous session (D72).
#
# In a request, `open` and `expanded` are newline-joined strings: params are
# flat strings. In the result they are JSON arrays.

# workspace.save {open <newline-joined paths>, ?active?, ?expanded?} -> {saved 1}
proc rio::ops::workspace_save {params} {
	set root [rio::project::root]
	set joined [expr {[dict exists $params open] ? [dict get $params open] : ""}]
	set active [expr {[dict exists $params active] ? [dict get $params active] : ""}]
	set exj    [expr {[dict exists $params expanded] ? [dict get $params expanded] : ""}]
	set open {}
	foreach p [split $joined "\n"] { if {$p ne ""} { lappend open $p } }
	set expanded {}
	foreach p [split $exj "\n"] { if {$p ne ""} { lappend expanded $p } }
	rio::workspace::save $root $open $active $expanded
	return [dict create result [dict create saved 1]]
}
rio::dispatch::register workspace.save rio::ops::workspace_save

# workspace.get -> {open <array of path>, active <path>, expanded <array of dir>}
# The saved session, pruned to files and directories that still exist on the
# core's disk. Empty when nothing was saved.
proc rio::ops::workspace_get {params} {
	set root [rio::project::root]
	set s [rio::workspace::get $root]
	set open {}
	foreach p [dict get $s open] { if {[file isfile $p]} { lappend open $p } }
	set active [dict get $s active]
	if {$active ne "" && ![file isfile $active]} { set active "" }
	set expanded {}
	foreach p [dict get $s expanded] { if {[file isdirectory $p]} { lappend expanded $p } }
	return [dict create result [dict create open $open active $active expanded $expanded]]
}
rio::dispatch::register workspace.get rio::ops::workspace_get
