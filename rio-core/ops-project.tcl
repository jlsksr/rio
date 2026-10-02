# rio-core — the project.* op namespace (D11).
#
# Thin handlers over rio::project. project.open also emits project.opened:
# every view cares.

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

# project.search {needle, ?nocase?, ?wholeword?, ?regex?} ->
#   {count, files, truncated, results:[{path, rel, matches:[{line, col, cols, lens, text}]}]}
# Find in Files (D51): every matching line in the open project, by file.
# No events.
proc rio::ops::project_search {params} {
	if {![dict exists $params needle] || [dict get $params needle] eq ""} {
		rio::error::raise bad_request "project.search requires a non-empty needle"
	}
	set nocase    [_flag $params nocase]
	set wholeword [_flag $params wholeword]
	set regex     [_flag $params regex]
	set r [rio::project::search [dict get $params needle] $nocase $wholeword $regex]
	return [dict create result $r]
}
rio::dispatch::register project.search rio::ops::project_search

# project.replace {needle, text, ?nocase?, ?wholeword?, ?regex?} ->
#   {count <occurrences>, files <disk files rewritten>, bufferids [ids edited]}
# Replace across the open project (D52). The search finds the files; then:
#
#   open in a buffer   rio::doc::replace_all: undoable, unsaved, buffer.changed
#   closed             rewritten on disk, encoding and EOL kept, fs.changed
#
# `bufferids` lets the frontend mark those buffers modified. The GUI confirms
# first: a closed file is changed on disk.
proc rio::ops::project_replace {params} {
	set needle [_needle $params project.replace]
	if {![dict exists $params text]} {
		rio::error::raise bad_request "project.replace requires text"
	}
	set repl      [dict get $params text]
	set nocase    [_flag $params nocase]
	set wholeword [_flag $params wholeword]
	set regex     [_flag $params regex]
	set sr [rio::project::search $needle $nocase $wholeword $regex]
	# Open-buffer paths -> ids, normalized to compare with the search's paths.
	set openbuf {}
	foreach b [rio::doc::inventory] {
		set p [dict get $b path]
		if {$p ne ""} { dict set openbuf [file normalize $p] [dict get $b buffer] }
	}
	set total 0 ; set diskfiles 0 ; set bufferids {} ; set events {}
	foreach f [dict get $sr results] {
		set path [dict get $f path]
		if {[dict exists $openbuf [file normalize $path]]} {
			# Open file: replace through the buffer.
			set id [dict get $openbuf [file normalize $path]]
			set ch [rio::doc::replace_all $id $needle $repl $nocase $wholeword $regex]
			if {$ch eq ""} continue
			incr total [dict get $ch count]
			lappend bufferids $id
			lappend events [dict create event buffer.changed params [dict create \
				buffer $id start [dict get $ch start] end [dict get $ch end] \
				text [dict get $ch text] removed [dict get $ch removed]]]
		} else {
			# Closed file: rewrite on disk.
			if {[catch {rio::fs::read $path} rd]} continue
			lassign [rio::doc::_replace_text [dict get $rd text] $needle $repl $nocase $wholeword $regex] \
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
