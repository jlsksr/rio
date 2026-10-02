# rio-core — the git.* op namespace (D11, D7).
#
# Thin handlers over rio::git.
#
# cwd: the `cwd` param, else the open project root, else the process's cwd.
proc rio::ops::_git_cwd {params} {
	if {[dict exists $params cwd]} { return [dict get $params cwd] }
	return [rio::project::root]
}

# One fs.changed per path a git write rewrote (D94), absolute, so the file
# pane repaints and open buffers notice. git's paths are relative to the repo
# root, which is the project root (D43).
proc rio::ops::_git_changed_evs {cwd paths} {
	if {$cwd eq ""} { set cwd [pwd] }
	set evs {}
	foreach p $paths {
		lappend evs [dict create event fs.changed \
			params [dict create path [file join $cwd $p]]]
	}
	return $evs
}

# git.status {?cwd?} -> {branch, changes:[{x,y,path,?orig?}]}
proc rio::ops::git_status {params} {
	return [dict create result [rio::git::status [_git_cwd $params]]]
}
rio::dispatch::register git.status rio::ops::git_status

# git.add {path, ?cwd?} -> {} ; stage the path.
proc rio::ops::git_add {params} {
	rio::git::add [_git_cwd $params] [dict get $params path]
	return [dict create result {}]
}
rio::dispatch::register git.add rio::ops::git_add

# git.unstage {path, ?cwd?} -> {} ; drop the path from the index (inverse of add).
proc rio::ops::git_unstage {params} {
	rio::git::unstage [_git_cwd $params] [dict get $params path]
	return [dict create result {}]
}
rio::dispatch::register git.unstage rio::ops::git_unstage

# git.commit {message, ?cwd?} -> {hash <short>} ; commit the staged index.
proc rio::ops::git_commit {params} {
	set hash [rio::git::commit [_git_cwd $params] [dict get $params message]]
	return [dict create result [dict create hash $hash]]
}
rio::dispatch::register git.commit rio::ops::git_commit

# git.discard {path, ?cwd?} -> {action revert|remove} ; discard a path's
# local changes (D80; the rules are in rio::git::discard). The GUI confirms
# first. Emits fs.changed for every path rewritten, two for a rename (D94).
proc rio::ops::git_discard {params} {
	set cwd  [_git_cwd $params]
	set path [dict get $params path]
	set r [rio::git::discard $cwd $path]
	return [dict create result [dict create action [dict get $r action]] \
		events [_git_changed_evs $cwd [dict get $r paths]]]
}
rio::dispatch::register git.discard rio::ops::git_discard

# git.discard_all {?cwd?} -> {count N} ; discard every local change (D93).
# `count` is the number of changed entries. Nothing to discard is a
# bad_request. Emits one fs.changed per path rewritten (D94).
proc rio::ops::git_discard_all {params} {
	set cwd [_git_cwd $params]
	set r [rio::git::discard_all $cwd]
	return [dict create result [dict create count [dict get $r count]] \
		events [_git_changed_evs $cwd [dict get $r paths]]]
}
rio::dispatch::register git.discard_all rio::ops::git_discard_all

# git.diff {?cwd?, ?path?, ?staged?} -> {diff <unified-diff text>}
proc rio::ops::git_diff {params} {
	set path   [expr {[dict exists $params path]   ? [dict get $params path]   : ""}]
	set staged [expr {[dict exists $params staged] ? [dict get $params staged] : 0}]
	return [dict create result [dict create diff [rio::git::diff [_git_cwd $params] $path $staged]]]
}
rio::dispatch::register git.diff rio::ops::git_diff

# git.log {?cwd?, ?max?, ?path?} -> {commits:[{hash,short,author,date,subject}]}
proc rio::ops::git_log {params} {
	set max  [expr {[dict exists $params max]  ? [dict get $params max]  : ""}]
	set path [expr {[dict exists $params path] ? [dict get $params path] : ""}]
	return [dict create result [rio::git::log [_git_cwd $params] $max $path]]
}
rio::dispatch::register git.log rio::ops::git_log
