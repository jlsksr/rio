# rio-core — the git.* op namespace (AGENTS.md D11, D7).
#
# Thin handlers over rio::git's read layer. No logic of their own beyond reading
# params and shaping the result; the porcelain parsing lives in rio::git.

# git.status {?cwd?} -> {branch, changes:[{x,y,path,?orig?}]}
proc rio::ops::git_status {params} {
	set cwd [expr {[dict exists $params cwd] ? [dict get $params cwd] : ""}]
	return [dict create result [rio::git::status $cwd]]
}
rio::dispatch::register git.status rio::ops::git_status

# git.diff {?cwd?, ?path?, ?staged?} -> {diff <unified-diff text>}
proc rio::ops::git_diff {params} {
	set cwd    [expr {[dict exists $params cwd]    ? [dict get $params cwd]    : ""}]
	set path   [expr {[dict exists $params path]   ? [dict get $params path]   : ""}]
	set staged [expr {[dict exists $params staged] ? [dict get $params staged] : 0}]
	return [dict create result [dict create diff [rio::git::diff $cwd $path $staged]]]
}
rio::dispatch::register git.diff rio::ops::git_diff
