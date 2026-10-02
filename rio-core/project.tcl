# rio-core — the project / workspace root (D11, the project.* namespace).
#
# One root folder, held by the core. Everything relative resolves against it:
# git's cwd, fs.list, the project's `.rio/` dir. One root at a time.
# No Tk, no protocol.

namespace eval rio::project {
	variable root ""   ;# absolute path of the open project, or "" if none
}

# Open `path`, an existing directory, as the project root. Returns the
# normalized root. It may replace another root.
proc rio::project::open {path} {
	variable root
	if {$path eq ""} {
		rio::error::raise bad_request "project.open requires a path"
	}
	set abs [file normalize $path]
	if {![file isdirectory $abs]} {
		rio::error::raise io_error "not a directory: $path"
	}
	set root $abs
	return $root
}

# The current root, or "" if no project is open.
proc rio::project::root {} {
	variable root
	return $root
}

# Resolve `path` against the project root:
#   ""         the root
#   /abs/x     as is
#   src/x      <root>/src/x
# Raises when a root is needed and no project is open.
proc rio::project::resolve {path} {
	variable root
	if {$path eq ""} {
		if {$root eq ""} {
			rio::error::raise bad_request "no path given and no project open"
		}
		return $root
	}
	if {[file pathtype $path] eq "absolute"} {
		return [file normalize $path]
	}
	if {$root eq ""} {
		rio::error::raise bad_request "relative path but no project open: $path"
	}
	return [file normalize [file join $root $path]]
}

# Forget the open project (its root becomes "").
proc rio::project::close {} {
	variable root
	set root ""
}

# --- project-wide text search (Find in Files, D51) -----------------
# Walk the open project's tree and return every line that contains `needle`,
# grouped by file. In the core: with a remote core only it sees the tree.
# - Same matcher and flags as the buffer search (rio::doc::grep_lines).
# - Skipped: `.git`, binary files, files over `search_max_bytes`.
# - One row per matching line; `count` is every hit.
# - At most `search_max_rows` rows; beyond that, `truncated` is 1.
variable rio::project::search_max_rows  2000
# Never shown to the user, so a round decimal number will do (compare
# rio::ops::open_max_bytes).
variable rio::project::search_max_bytes 2000000

proc rio::project::search {needle nocase wholeword {regex 0}} {
	variable root
	variable search_max_rows
	if {$root eq ""} {
		rio::error::raise bad_request "no project open"
	}
	if {$needle eq ""} {
		rio::error::raise bad_request "project.search requires a non-empty needle"
	}
	set files {}
	_search_walk $root files
	set results {}
	set total 0
	set rows 0
	set truncated 0
	foreach path [lsort -dictionary $files] {
		if {$rows >= $search_max_rows} { set truncated 1 ; break }
		lassign [_search_file $path $needle $nocase $wholeword [expr {$search_max_rows - $rows}] $regex] \
			matches occ trunc
		if {[llength $matches] == 0} continue
		incr total $occ
		incr rows [llength $matches]
		if {$trunc} { set truncated 1 }
		set rel $path
		if {[string first "$root/" "$path/"] == 0} {
			set rel [string range $path [expr {[string length $root] + 1}] end]
		}
		lappend results [dict create path $path rel $rel matches $matches]
		if {$truncated} break
	}
	return [dict create count $total files [llength $results] \
		truncated $truncated results $results]
}

# Collect the files under `dir` into the list var `accVar`, skipping `.git`.
# Other dotfiles are searched.
proc rio::project::_search_walk {dir accVar} {
	upvar 1 $accVar acc
	foreach e [rio::fs::listdir $dir] {
		set name [dict get $e name]
		set p [file join $dir $name]
		if {[dict get $e type] eq "dir"} {
			if {$name eq ".git"} continue
			_search_walk $p acc
		} else {
			lappend acc $p
		}
	}
}

# Search one file. Returns {matches occurrences truncated}; the rows are
# rio::doc::grep_lines' (D52). `truncated` is 1 when the file had more
# matching lines than `budget`; the rest are dropped. A file that is too
# large, binary or unreadable gives no rows.
proc rio::project::_search_file {path needle nocase wholeword budget {regex 0}} {
	variable search_max_bytes
	# rio::fs::classify (D125) is file.open's rule too. It probes only the
	# file's head, so the whole text is tested for a NUL again below.
	if {[dict get [rio::fs::classify $path $search_max_bytes] verdict] ne "ok"} {
		return [list {} 0 0]
	}
	if {[catch {rio::fs::read $path} rd]} { return [list {} 0 0] }
	set text [dict get $rd text]
	if {[string first "\x00" $text] >= 0} { return [list {} 0 0] }
	lassign [rio::doc::grep_lines [split $text "\n"] $needle $nocase $wholeword 200 $regex] matches occ
	set trunc 0
	if {[llength $matches] > $budget} {
		set matches [lrange $matches 0 [expr {$budget - 1}]]
		set trunc 1
		set occ 0
		foreach m $matches { incr occ [llength [dict get $m cols]] }
	}
	return [list $matches $occ $trunc]
}
