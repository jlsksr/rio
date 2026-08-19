# rio-core — the project.* op namespace (AGENTS.md D11).
#
# Thin handlers over rio::project's root state. Opening a project is a state
# change every view cares about (the git pane should refresh, the file tree
# should load), so project.open broadcasts a project.opened event (D3/D11) in
# addition to replying to the caller.

# project.open {path} -> {root} ; emits project.opened to all views.
proc rio::ops::project_open {params} {
	if {![dict exists $params path]} {
		rio::error::raise bad_request "project.open requires a path"
	}
	set root [rio::project::open [dict get $params path]]
	set ev [dict create event project.opened params [dict create root $root]]
	return [dict create result [dict create root $root] events [list $ev]]
}
rio::dispatch::register project.open rio::ops::project_open

# project.get -> {root} ; the open project's root, or "" if none. A pure query.
proc rio::ops::project_get {params} {
	return [dict create result [dict create root [rio::project::root]]]
}
rio::dispatch::register project.get rio::ops::project_get

# project.search {needle, ?nocase?} ->
#   {count, files, truncated, results:[{path, rel, matches:[{line, col, text}]}]}
# Find in Files (D51): every line matching `needle` across the open project's
# tree, grouped by file. Core-side because only the core can see the tree in
# remote mode (D36). A two-level nested result, so the wire layer registers a
# shape encoder (D25). A pure query — no events.
proc rio::ops::project_search {params} {
	if {![dict exists $params needle] || [dict get $params needle] eq ""} {
		rio::error::raise bad_request "project.search requires a non-empty needle"
	}
	set nocase [expr {[dict exists $params nocase] && [dict get $params nocase] ? 1 : 0}]
	set r [rio::project::search [dict get $params needle] $nocase]
	return [dict create result $r]
}
rio::dispatch::register project.search rio::ops::project_search
