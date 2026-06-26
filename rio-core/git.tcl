# rio-core — git, by shelling out to `git` and parsing porcelain (AGENTS.md D7).
#
# No libgit2: we run the installed `git` through the command-execution primitive
# (rio::exec, D15) and parse its machine-readable output. Portable and
# dependency-light — it works identically everywhere `git` is installed.
#
# This is the read layer (status, diff): pure data ops that git's UI (and the
# agent) build on. It carries no UI — output surfaces in whatever flow asked.

namespace eval rio::git {}

# Run `git <args>` in $cwd and return its stdout. A non-zero git exit (not a
# repo, bad path, …) is surfaced as bad_request with git's own stderr — the
# caller pointed us somewhere git can't honour. (git missing entirely raises
# io_error from rio::exec's launch path, before we get here.)
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

# git.status: parse `status --porcelain=v1 -b -z` into {branch, changes}, where
# each change is {x y path ?orig?} — X/Y the staged/worktree status chars, and
# orig the source path for a rename/copy (R/C). -z makes records NUL-terminated,
# so paths with spaces or newlines parse cleanly.
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

# git.diff: the unified diff text. `staged` selects the index (--cached); `path`
# limits it to one file. Returned raw for the caller to render.
proc rio::git::diff {cwd path staged} {
	set args diff
	if {$staged} { lappend args --cached }
	if {$path ne ""} { lappend args -- $path }
	return [_run $cwd {*}$args]
}

# git.log: newest-first commits as {hash, short, author, date, subject}. We pin a
# field-delimited --pretty (US 0x1f between fields) under -z (NUL between commits)
# so subjects with spaces, and any field, parse unambiguously. `max` caps the
# count; `path` limits to a file's history. A repo with no commits yet errors
# (bad_request) — that's git's own behaviour for `log`.
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
