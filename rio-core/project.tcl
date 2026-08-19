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

proc rio::project::search {needle nocase wholeword} {
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
	set hay $needle
	if {$nocase} { set hay [string tolower $needle] }
	set nlen [string length $needle]
	set results {}
	set total 0
	set rows 0
	set truncated 0
	foreach path [lsort -dictionary $files] {
		if {$rows >= $search_max_rows} { set truncated 1 ; break }
		lassign [_search_file $path $hay $nlen $nocase $wholeword [expr {$search_max_rows - $rows}]] \
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

# Search one file. Returns {matches occurrences truncated}: `matches` is a list of
# {line col cols text} for each matching line — `cols` is the 1-based start column
# of EVERY occurrence on the line (for the frontend's per-match highlight, D51), and
# `col` is the first (the jump target); line/col are 1-based, text is capped for the
# view. `occurrences` counts every hit (a line may hold several), `truncated` is 1 if
# the per-call row `budget` was reached. Skips a file that is too large, is binary
# (holds a NUL), or won't read — a search silently passes over what it can't show.
proc rio::project::_search_file {path hay nlen nocase wholeword budget} {
	variable search_max_bytes
	if {[catch {file size $path} sz] || $sz > $search_max_bytes} { return [list {} 0 0] }
	if {[catch {rio::fs::read $path} rd]} { return [list {} 0 0] }
	set text [dict get $rd text]
	if {[string first "\x00" $text] >= 0} { return [list {} 0 0] }
	set matches {}
	set occ 0
	set trunc 0
	set ln 0
	foreach line [split $text "\n"] {
		incr ln
		set h $line
		if {$nocase} { set h [string tolower $line] }
		set cols [_line_hits $h $hay $nlen $wholeword]
		if {[llength $cols] == 0} continue
		incr occ [llength $cols]
		lappend matches [dict create line $ln col [lindex $cols 0] cols $cols \
			text [string range $line 0 199]]
		if {[llength $matches] >= $budget} { set trunc 1 ; break }
	}
	return [list $matches $occ $trunc]
}

# The 1-based start columns of every occurrence of `hay` (length `nlen`) in the
# haystack line `h`. With `wholeword`, an occurrence counts only when the span is
# not flanked by a word character on either side (or sits at a line edge) — the
# \m…\M feel without paying for a regex per line.
proc rio::project::_line_hits {h hay nlen wholeword} {
	set cols {}
	set from 0
	while {1} {
		set i [string first $hay $h $from]
		if {$i < 0} break
		if {!$wholeword || [_word_bounded $h $i $nlen]} {
			lappend cols [expr {$i + 1}]
		}
		set from [expr {$i + $nlen}]
	}
	return $cols
}

# True iff the [i, i+nlen) span in `h` has a non-word char (or nothing) on both
# flanks — the whole-word test. A word char is a letter, digit, or underscore
# (Unicode letters included, via `string is alnum`).
proc rio::project::_word_bounded {h i nlen} {
	set before [expr {$i - 1}]
	set after  [expr {$i + $nlen}]
	if {$before >= 0 && [_word_char [string index $h $before]]} { return 0 }
	if {$after < [string length $h] && [_word_char [string index $h $after]]} { return 0 }
	return 1
}
proc rio::project::_word_char {ch} {
	return [expr {$ch eq "_" || [string is alnum -strict $ch]}]
}
