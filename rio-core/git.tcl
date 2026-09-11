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

# git.add: track/stage a path — `git add -- <path>`. An untracked file becomes
# tracked+staged; a modified tracked file has its worktree changes staged. This is
# the first git WRITE op (D7 was read-only status/diffs); it carries no result.
proc rio::git::add {cwd path} {
	_run $cwd add -- $path
	return ""
}

# git.unstage: the inverse of add — `git reset -q -- <path>` drops the path from the
# index (a staged-add returns to untracked; a staged modification returns to modified-
# unstaged). `reset` rather than `restore --staged` so it also works on an unborn HEAD
# (a repo with no commits yet), where `restore --staged` cannot resolve HEAD.
proc rio::git::unstage {cwd path} {
	_run $cwd reset -q -- $path
	return ""
}

# git.discard: throw away a path's local changes (D80) — the destructive counterpart to
# add/unstage/commit, for the everyday "undo my edits to this file". Behaviour is keyed
# on the path's own porcelain staged char X:
#   ?  (untracked)       -> remove the new file:   `git clean -fd -- <path>`
#   A  (staged addition) -> unstage, then remove:  `git reset` then `git clean -fd`
#   C  (staged copy)     -> the same: a copy IS a new file, and its source is untouched by
#                           the copy, so there is nothing to put back there
#   R  (staged rename)   -> put the file back under its OLD name (D97), see below
#   else (tracked M/D/…) -> revert to the last commit, dropping BOTH the staged and the
#                           worktree change:  `git restore --staged --worktree -- <path>`
# The restore branch only runs for a file with a committed baseline, so HEAD always
# exists there — the unborn-HEAD case (no commits) is only ?/A, handled above — so unlike
# unstage this can safely use `restore`. Returns {action revert|remove, paths {...}}:
# `action` words the frontend's confirmation, `paths` is every file the call rewrote, which
# the op turns into fs.changed events (D94) — two of them for a rename. A path with no
# changes is a bad_request.
#
# The status lookup goes through the full `status` rather than `status -- <path>`: rename
# detection needs BOTH ends of the rename in the same diff, so narrowing the pathspec to the
# new name alone makes git report a plain `A` and the rename would be invisible here.
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
		# A rename is one change with two names, so undoing it takes both: empty the index
		# of each (back to HEAD — the old name returns to it, the new name leaves it), write
		# the old name back to disk from that index, and clean away the new name, which the
		# unstage has just turned into an ordinary untracked file. `restore --worktree` on
		# the new name would be wrong (it is not in HEAD, so there is nothing to write) and
		# leaving it would turn a rename into a copy.
		set orig [dict get $entry orig]
		_run $cwd restore --staged -- $path $orig
		_run $cwd restore --worktree -- $orig
		_run $cwd clean -fd -- $path
		return [dict create action revert paths [list $path $orig]]
	}
	_run $cwd restore --staged --worktree -- $path
	return [dict create action revert paths [list $path]]
}

# The status entry for PATH, or "" when git reports no change under that name. Every caller
# that needs to know WHAT a path's change is shares this, and they all need the wide lookup
# described above: `status -- <path>` cannot see a rename, so the one question worth asking
# has to be asked of the whole status.
proc rio::git::_entry {cwd path} {
	foreach c [dict get [status $cwd] changes] {
		if {[dict get $c path] eq $path} { return $c }
	}
	return ""
}

# Has this repo a commit yet? A non-zero exit is the ANSWER here ("unborn HEAD"), not a
# failure, so this goes around _run rather than through it (_run would raise).
proc rio::git::_has_head {cwd} {
	set r [rio::exec::run [list git rev-parse --verify -q HEAD] $cwd]
	return [expr {[dict get $r exitcode] == 0}]
}

# git.discard_all: throw away EVERY local change at once (D93) — the bulk form of discard,
# for "put this project back the way the last commit left it". It is the per-path rule
# applied to the whole repo, but NOT a loop over the paths: two git commands, one round
# trip, so a channel that drops mid-way (D29) can't leave a half-discarded tree.
#   HEAD exists -> `git reset -q --hard`  : index AND worktree back to HEAD — every tracked
#                  modification and deletion reverted, every staged addition demoted to a
#                  plain untracked file
#   unborn HEAD -> `git reset -q`         : there is nothing to revert *to*, so only empty
#                  the index (`--hard` can't resolve HEAD on older git; plain `reset` is
#                  the same choice D44's unstage made)
# then `git clean -fd -- :/` removes what is left — the untracked files, the former staged
# additions among them. `:/` is git's repo-root pathspec, so the sweep covers the whole repo
# however deep the cwd sits; no `-x`, so IGNORED files (build output, a local .env) survive:
# discarding your edits must not cost you untracked state git was told to disregard.
# Returns {count N paths {...}}: N is how many changed ENTRIES the pane showed (what the
# frontend's confirmation counted), and paths are the repo-relative files touched, which the
# op turns into fs.changed events (D94). The two differ by renames — one entry, but BOTH
# names change on disk when the rename is reverted, so both are listed. A repo with nothing
# to discard is a bad_request, like the per-path op.
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

# git.commit: record the staged index as a commit — `git commit -m <msg>`. The second
# git write family after D44's add/unstage. We lean on git's own guards, surfaced as
# bad_request by _run: an empty message (`commit -m ""` aborts) and nothing staged
# ("nothing to commit") both fail honestly with git's wording — no pre-checks here.
# Returns the new HEAD's short hash, for the frontend to confirm the commit.
proc rio::git::commit {cwd msg} {
	_run $cwd commit -m $msg
	return [string trim [_run $cwd rev-parse --short HEAD]]
}

# git.diff: the unified diff text. `staged` selects the index (--cached); `path`
# limits it to one file. Returned raw for the caller to render.
#
# A RENAME has to be asked for by BOTH of its names, for the same reason discard's lookup is
# wide (D97): rename detection needs both ends inside the pathspec, so `diff --cached -- new`
# makes git report a whole-file ADDITION — it cannot see where the file came from, so it
# describes the change as the one thing it is not. Only the staged side needs this: an
# unstaged diff compares the index and the worktree, which hold the file under the same name,
# so `RM`'s worktree half is already right. That also keeps the extra status off every
# ordinary row click.
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
