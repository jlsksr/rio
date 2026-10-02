# rio-core — git, by shelling out to `git` and parsing porcelain (D7).
#
# No libgit2: rio runs the installed `git` through rio::exec (D15) and parses
# its machine-readable output. Data only, no UI.

namespace eval rio::git {}

# Run `git <args>` in $cwd and return its stdout. A non-zero exit is a
# bad_request carrying git's stderr. A missing git is rio::exec's io_error.
proc rio::git::_run {cwd args} {
	set r [rio::exec::run [list git {*}$args] $cwd]
	if {[dict get $r exitcode] != 0} {
		set msg [string trim [dict get $r stderr]]
		if {$msg eq ""} { set msg "git failed (exit [dict get $r exitcode])" }
		rio::error::raise bad_request $msg
	}
	return [dict get $r stdout]
}

# The local branch name from a `## ...` porcelain branch header, e.g.
#   "main...origin/main [ahead 1]" -> main ;  "No commits yet on main" -> main
#   "HEAD (no branch)" -> HEAD (detached)
proc rio::git::_branch_name {hdr} {
	if {[string match "No commits yet on *" $hdr]} {
		return [string range $hdr 18 end]
	}
	set first [lindex [split $hdr] 0]           ;# token before " [ahead/behind]"
	set sep [string first "..." $first]          ;# strip the upstream half
	if {$sep >= 0} { set first [string range $first 0 $sep-1] }
	return $first
}

# git.status: parse `status --porcelain=v1 -b -z` into {branch changes}. A
# change is {x y path ?orig?}: x and y are the staged and worktree status
# chars, orig the source of a rename or copy. -z: NUL-terminated records, so
# any path parses.
proc rio::git::status {cwd} {
	set out [_run $cwd status --porcelain=v1 -b -z]
	set recs [split $out \0]
	if {[llength $recs] && [lindex $recs end] eq ""} {
		set recs [lrange $recs 0 end-1]          ;# drop the trailing-NUL empty
	}
	set branch ""
	set changes {}
	for {set i 0} {$i < [llength $recs]} {incr i} {
		set rec [lindex $recs $i]
		if {[string match "## *" $rec]} {
			set branch [_branch_name [string range $rec 3 end]]
			continue
		}
		set x [string index $rec 0]
		set y [string index $rec 1]
		set entry [dict create x $x y $y path [string range $rec 3 end]]
		if {$x eq "R" || $x eq "C"} {
			# A rename/copy's original path is the next NUL field (-z format).
			dict set entry orig [lindex $recs [incr i]]
		}
		lappend changes $entry
	}
	return [dict create branch $branch changes $changes]
}

# git.add: stage a path, `git add -- <path>`.
proc rio::git::add {cwd path} {
	_run $cwd add -- $path
	return ""
}

# git.unstage: `git reset -q -- <path>`. `reset`, not `restore --staged`: it
# also works in a repo without a commit.
proc rio::git::unstage {cwd path} {
	_run $cwd reset -q -- $path
	return ""
}

# git.discard: throw away a path's local changes (D80). By the path's staged
# status char:
#   ?  untracked        remove it:              `git clean -fd -- <path>`
#   A  staged addition  unstage, then remove:   `git reset`, `git clean -fd`
#   C  staged copy      the same: a copy is a new file
#   R  staged rename    back under its old name (D97), see below
#   else  M, D, …       back to the last commit, staged and worktree:
#                       `git restore --staged --worktree -- <path>`
# Returns {action revert|remove, paths {...}}: `paths` is every file rewritten,
# two for a rename (they become fs.changed events, D94). A path without
# changes is a bad_request.
proc rio::git::discard {cwd path} {
	set entry [_entry $cwd $path]
	if {$entry eq ""} {
		rio::error::raise bad_request "nothing to discard for $path"
	}
	set x [dict get $entry x]
	if {$x eq "?"} {
		_run $cwd clean -fd -- $path
		return [dict create action remove paths [list $path]]
	} elseif {$x eq "A" || $x eq "C"} {
		_run $cwd reset -q -- $path
		_run $cwd clean -fd -- $path
		return [dict create action remove paths [list $path]]
	} elseif {$x eq "R"} {
		# A rename has two names: unstage both, write the old name back to
		# disk, remove the new one, which is now untracked.
		set orig [dict get $entry orig]
		_run $cwd restore --staged -- $path $orig
		_run $cwd restore --worktree -- $orig
		_run $cwd clean -fd -- $path
		return [dict create action revert paths [list $path $orig]]
	}
	_run $cwd restore --staged --worktree -- $path
	return [dict create action revert paths [list $path]]
}

# The status entry for `path`, or "". Looked up in the full status:
# `status -- <path>` sees only one end of a rename and reports a plain `A`.
proc rio::git::_entry {cwd path} {
	foreach c [dict get [status $cwd] changes] {
		if {[dict get $c path] eq $path} { return $c }
	}
	return ""
}

# Has this repo a commit yet? A non-zero exit is the answer "no", so this
# does not go through _run, which would raise.
proc rio::git::_has_head {cwd} {
	set r [rio::exec::run [list git rev-parse --verify -q HEAD] $cwd]
	return [expr {[dict get $r exitcode] == 0}]
}

# git.discard_all: throw away every local change (D93). Two git commands in
# one op, not a loop over paths, so a dropped channel leaves no half-done tree.
#   1. a commit exists:  `git reset -q --hard`   index and worktree back to HEAD
#      no commit yet:    `git reset -q`          only empty the index
#   2. `git clean -fd -- :/`   remove what is untracked now, repo-wide.
#      No `-x`: ignored files (build output, a local .env) survive.
# Returns {count N paths {...}}: N changed entries, and every file touched. A
# rename is one entry and two paths. Nothing to discard is a bad_request.
proc rio::git::discard_all {cwd} {
	set changes [dict get [status $cwd] changes]
	if {![llength $changes]} {
		rio::error::raise bad_request "nothing to discard"
	}
	set paths {}
	foreach c $changes {
		lappend paths [dict get $c path]
		if {[dict exists $c orig]} { lappend paths [dict get $c orig] }
	}
	if {[_has_head $cwd]} {
		_run $cwd reset -q --hard
	} else {
		_run $cwd reset -q
	}
	_run $cwd clean -fd -- :/
	return [dict create count [llength $changes] paths $paths]
}

# git.commit: `git commit -m <msg>`. No checks of its own: an empty message
# or nothing staged fails with git's wording. Returns the new short hash.
proc rio::git::commit {cwd msg} {
	_run $cwd commit -m $msg
	return [string trim [_run $cwd rev-parse --short HEAD]]
}

# git.diff: the unified diff text. `staged` selects the index (--cached); `path`
# limits it to one file. Returned raw for the caller to render.
#
# A staged rename is asked for by both names (D97): with the new name alone
# git reports a whole-file addition. An unstaged diff needs no such lookup.
proc rio::git::diff {cwd path staged} {
	set args diff
	if {$staged} { lappend args --cached }
	if {$path ne ""} {
		lappend args -- $path
		if {$staged} {
			set entry [_entry $cwd $path]
			if {$entry ne "" && [dict get $entry x] eq "R"} {
				lappend args [dict get $entry orig]
			}
		}
	}
	return [_run $cwd {*}$args]
}

# git.log: commits, newest first, as {hash short author date subject}. Fields
# are separated by 0x1f and commits by NUL, so any subject parses. `max` caps
# the count; `path` limits it to one file. A repo without a commit is a
# bad_request, as git itself fails.
proc rio::git::log {cwd max path} {
	set args [list log --pretty=format:%H%x1f%h%x1f%an%x1f%aI%x1f%s -z]
	if {$max ne "" && $max > 0} { lappend args --max-count=$max }
	if {$path ne ""} { lappend args -- $path }
	set commits {}
	foreach rec [split [_run $cwd {*}$args] \0] {
		if {$rec eq ""} continue
		lassign [split $rec \x1f] hash short author date subject
		lappend commits [dict create hash $hash short $short \
			author $author date $date subject $subject]
	}
	return [dict create commits $commits]
}
