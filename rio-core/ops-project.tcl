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

# project.search {needle, ?nocase?, ?wholeword?} ->
#   {count, files, truncated, results:[{path, rel, matches:[{line, col, cols, text}]}]}
# Find in Files (D51): every line matching `needle` across the open project's
# tree, grouped by file. Core-side because only the core can see the tree in
# remote mode (D36). A two-level nested result, so the wire layer registers a
# shape encoder (D25). A pure query — no events.
proc rio::ops::project_search {params} {
	if {![dict exists $params needle] || [dict get $params needle] eq ""} {
		rio::error::raise bad_request "project.search requires a non-empty needle"
	}
	set nocase    [expr {[dict exists $params nocase]    && [dict get $params nocase]    ? 1 : 0}]
	set wholeword [expr {[dict exists $params wholeword] && [dict get $params wholeword] ? 1 : 0}]
	set r [rio::project::search [dict get $params needle] $nocase $wholeword]
	return [dict create result $r]
}
rio::dispatch::register project.search rio::ops::project_search

# project.replace {needle, text, ?nocase?, ?wholeword?} ->
#   {count <occurrences>, files <disk files rewritten>, bufferids [ids edited]}
# Replace across the whole open project (D52 Phase B) — the destructive sibling of
# project.search. It reuses the search to find the matching files (same skip rules:
# .git, binary, oversized), then routes each by whether it is OPEN in the editor:
#   - open buffer → rio::doc::replace_all (in-core, undoable, one buffer.changed; the
#     change stays UNSAVED in the buffer so an open view never diverges from disk —
#     the open-vs-closed split the agent's writes use, agent-tools apply_write);
#   - closed file → rewritten on disk via rio::fs::write (one fs.changed), the
#     encoding / EOL preserved like file.save.
# The buffer.changed / fs.changed events are shaped like buffer.replace_all's and
# fs.write's and forwarded so views update. `bufferids` lets the frontend
# flag the edited buffers modified (their changes are unsaved). Destructive on disk
# for closed files — the GUI gates it behind a confirm; the core just does the work.
proc rio::ops::project_replace {params} {
	set needle [_needle $params project.replace]
	if {![dict exists $params text]} {
		rio::error::raise bad_request "project.replace requires text"
	}
	set repl      [dict get $params text]
	set nocase    [_flag $params nocase]
	set wholeword [_flag $params wholeword]
	# The matching files (empty needle / no project already raised by search).
	set sr [rio::project::search $needle $nocase $wholeword]
	# Open-buffer paths -> ids, so an open file is replaced through its buffer.
	# Normalized on both sides so a buffer path in a different-but-equivalent form
	# still matches the search's absolute path (search paths are already normalized).
	set openbuf {}
	foreach b [rio::doc::inventory] {
		set p [dict get $b path]
		if {$p ne ""} { dict set openbuf [file normalize $p] [dict get $b buffer] }
	}
	set total 0 ; set diskfiles 0 ; set bufferids {} ; set events {}
	foreach f [dict get $sr results] {
		set path [dict get $f path]
		if {[dict exists $openbuf [file normalize $path]]} {
			# Open file: replace THROUGH the buffer (undoable, unsaved), shaping the
			# same buffer.changed event buffer.replace_all emits.
			set id [dict get $openbuf [file normalize $path]]
			set ch [rio::doc::replace_all $id $needle $repl $nocase $wholeword]
			if {$ch eq ""} continue
			incr total [dict get $ch count]
			lappend bufferids $id
			lappend events [dict create event buffer.changed params [dict create \
				buffer $id start [dict get $ch start] end [dict get $ch end] \
				text [dict get $ch text] removed [dict get $ch removed]]]
		} else {
			# Closed file: rewrite on disk, preserving encoding/EOL, then fs.changed.
			if {[catch {rio::fs::read $path} rd]} continue
			lassign [rio::doc::_replace_text [dict get $rd text] $needle $repl $nocase $wholeword] \
				newtext n
			if {!$n} continue
			set meta {}
			foreach k {encoding eol bom} {
				if {[dict exists $rd $k]} { dict set meta $k [dict get $rd $k] }
			}
			if {[catch {rio::fs::write $path $newtext $meta}]} continue
			incr total $n
			incr diskfiles
			lappend events [dict create event fs.changed params [dict create path $path]]
		}
	}
	return [dict create result [dict create count $total files $diskfiles \
		bufferids $bufferids] events $events]
}
rio::dispatch::register project.replace rio::ops::project_replace
