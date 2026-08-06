# rio-core — the git.* op namespace (AGENTS.md D11, D7).
#
# Thin handlers over rio::git's read layer. No logic of their own beyond reading
# params and shaping the result; the porcelain parsing lives in rio::git.
#
# cwd defaults to the open project root (project.*), so a frontend just calls
# git.status with no cwd and gets the open project's git — the git pane no longer
# leans on the core process's own working directory. An explicit cwd overrides it
# (e.g. a tool operating on some other checkout); with neither, rio::git falls
# back to the process cwd as before.
proc rio::ops::_git_cwd {params} {
	if {[dict exists $params cwd]} { return [dict get $params cwd] }
	return [rio::project::root]
}

# git.status {?cwd?} -> {branch, changes:[{x,y,path,?orig?}]}
proc rio::ops::git_status {params} {
	return [dict create result [rio::git::status [_git_cwd $params]]]
}
rio::dispatch::register git.status rio::ops::git_status

# git.add {path, ?cwd?} -> {} ; track/stage the path (the first git write op).
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
