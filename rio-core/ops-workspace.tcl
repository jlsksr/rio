# rio-core — the workspace.* op namespace (AGENTS.md D31).
#
# Persist/restore "which files were open" per project, so a frontend can resume a
# working space. Keyed by the OPEN PROJECT ROOT (rio::project) — the frontend never
# names the root, removing the chance of pointing a session at the wrong tree. With
# no project open, the empty root selects the ANONYMOUS session (D72) — the loose
# "daily workspace" of files that span folders and share no root — so it persists and
# resumes too. The store (rio::workspace) is out-of-tree and, being core-side, follows
# the project onto a remote host (D30).
#
# `open` crosses the wire as a NEWLINE-JOINED string, not a JSON array: an inbound
# param rides the flat string-valued object the transport uses for every op (a path
# holds no newline, which the conf format assumes too, D21). The RESULT direction
# is a proper JSON array (the wire encoder for this op) — the asymmetry is only
# because params are flat strings, replies are shaped.

# workspace.save {open <newline-joined paths>, ?active?} -> {saved 1}
# Records the session for the open project, or the anonymous session when none is open
# (D72). The empty root is a valid key (rio::workspace reserves a file for it), so this
# always saves.
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
# The saved session for the open project — or the anonymous session when none is open
# (D72) — PRUNED to paths that still exist: a file deleted or moved since last time
# silently drops out, so a resume never spams "can't open" for stale entries. The
# unfolded-tree set (D89) is pruned the same way, against `file isdirectory` — a folder
# gone since last time simply isn't re-expanded. Existence is judged on the CORE's
# filesystem, the right one in remote mode. Empty when nothing was saved for that key.
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
