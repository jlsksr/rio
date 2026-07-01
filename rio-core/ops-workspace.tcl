# rio-core — the workspace.* op namespace (AGENTS.md D31).
#
# Persist/restore "which files were open" per project, so a frontend can resume a
# working space. Keyed by the OPEN PROJECT ROOT (rio::project) — the frontend never
# names the root, removing the chance of pointing a session at the wrong tree; with
# no project open there is nothing to key by, so save is a quiet no-op and get is
# empty. The store (rio::workspace) is out-of-tree and, being core-side, follows
# the project onto a remote host (D30).
#
# `open` crosses the wire as a NEWLINE-JOINED string, not a JSON array: an inbound
# param rides the flat string-valued object the transport uses for every op (a path
# holds no newline, which the conf format assumes too, D21). The RESULT direction
# is a proper JSON array (the wire encoder for this op) — the asymmetry is only
# because params are flat strings, replies are shaped.

# workspace.save {open <newline-joined paths>, ?active?} -> {saved <0|1>}
# Records the session for the open project. Empty `open` (or no project) saves
# nothing meaningful; saved=0 means "no project was open".
proc rio::ops::workspace_save {params} {
	set root [rio::project::root]
	if {$root eq ""} { return [dict create result [dict create saved 0]] }
	set joined [expr {[dict exists $params open] ? [dict get $params open] : ""}]
	set active [expr {[dict exists $params active] ? [dict get $params active] : ""}]
	set open {}
	foreach p [split $joined "\n"] { if {$p ne ""} { lappend open $p } }
	rio::workspace::save $root $open $active
	return [dict create result [dict create saved 1]]
}
rio::dispatch::register workspace.save rio::ops::workspace_save

# workspace.get -> {open <array of path>, active <path>}
# The open project's saved session, PRUNED to paths that still exist — a file
# deleted or moved since last time silently drops out, so a resume never spams
# "can't open" for stale entries. Existence is judged on the CORE's filesystem,
# the right one in remote mode. Empty when no project is open or none was saved.
proc rio::ops::workspace_get {params} {
	set root [rio::project::root]
	if {$root eq ""} { return [dict create result [dict create open {} active ""]] }
	set s [rio::workspace::get $root]
	set open {}
	foreach p [dict get $s open] { if {[file isfile $p]} { lappend open $p } }
	set active [dict get $s active]
	if {$active ne "" && ![file isfile $active]} { set active "" }
	return [dict create result [dict create open $open active $active]]
}
rio::dispatch::register workspace.get rio::ops::workspace_get
