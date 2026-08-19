# rio-core — the project / workspace root (AGENTS.md D11, the project.* namespace).
#
# rio is "the editor with a project open": one canonical root folder the core
# holds, which anchors everything that is otherwise relative — git operations
# (the cwd for git.*), directory listing for the file tree (fs.list), and the
# per-project `.rio/` config dir. Before this, git.* leaned on the core process's
# own working directory; the root makes "the project" an explicit, queryable
# fact instead of an accident of how rio was launched.
#
# Single-root by design (a workspace is one open folder, matching one git repo);
# multi-root can grow later without changing this seam. Pure state — no Tk, no
# protocol — so it tests headless.

namespace eval rio::project {
	variable root ""   ;# absolute path of the open project, or "" if none
}

# Open `path` as the project root: it must be an existing directory. Returns the
# normalized absolute root. Replacing one root with another is allowed (the
# caller decides what that means for open buffers; the model just records it).
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

# Resolve `path` against the project root the way a frontend means it: an empty
# path is the root itself; an absolute path is taken as-is; a relative path is
# joined onto the root. Raises if there is nothing to resolve against (no path
# and no open project) — callers that need a concrete directory use this.
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

# --- project-wide text search (Find in Files, AGENTS.md D51) -----------------
# Walk the open project's tree and return every LINE that contains `needle`,
# grouped by file. Pure logic over rio::fs (listdir + read), so it tests headless
# and — the load-bearing reason — runs core-side: in remote mode only the core
# can see the project tree (D36's "find-in-files is necessarily core-side" note),
# so the in-buffer search ops (D36) and this share one engine, not two.
#
# Scope kept small for v1: a plain substring match (optionally case-insensitive,
# mirroring buffer.find's `nocase`), skipping the VCS dir (.git), binary files (a
# NUL byte), and oversized files. Whole-word / regex / glob filters are deferred.
# One row per matching line (jumping to the first hit on it); `count` is total
# occurrences (a line with two hits shows once but counts twice, like VSCode).
# Rows are capped so a broad needle can't walk away with the core; the cap
# surfaces as `truncated`.
variable rio::project::search_max_rows  2000
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

# Recursively collect the regular files under `dir` into the list var `accVar`,
# skipping the VCS metadata dir so a search never wanders into .git/. Other
# dotfiles stay searchable (the files pane shows them too — filtering is a
# frontend choice, D22/fs.listdir).
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

# Search one file. Returns {matches occurrences truncated}: the same line-grouped
# {line col cols text} rows the Search panel renders — produced by the shared
# rio::doc::grep_lines (D52), so the disk walk and the open-buffer walk
# (buffers.search) use one matcher. `truncated` is 1 when the file held more
# matching lines than the per-call row `budget` (the rest are dropped and the
# occurrence total is recomputed over the kept rows). Skips a file that is too
# large, is binary (holds a NUL), or won't read — a search silently passes over
# what it can't show.
proc rio::project::_search_file {path needle nocase wholeword budget {regex 0}} {
	variable search_max_bytes
	if {[catch {file size $path} sz] || $sz > $search_max_bytes} { return [list {} 0 0] }
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
