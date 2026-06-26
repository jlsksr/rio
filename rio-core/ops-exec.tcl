# rio-core — the exec.* op namespace (AGENTS.md D11, D15).
#
# A thin handler over rio::exec::run: the command-execution primitive surfaced on
# the protocol so any frontend, git (D7), or the agent (D20) can run a command
# and get back {exitcode, stdout, stderr}. No logic of its own.

# exec.run {argv, ?cwd?, ?stdin?} -> {exitcode, stdout, stderr}
# argv is an argument vector (no shell). A non-zero exit is a successful op whose
# exitcode is data; only a failure to launch the command errors (io_error).
proc rio::ops::exec_run {params} {
	if {![dict exists $params argv]} {
		rio::error::raise bad_request "exec.run requires argv"
	}
	set argv  [dict get $params argv]
	set cwd   [expr {[dict exists $params cwd]   ? [dict get $params cwd]   : ""}]
	set stdin [expr {[dict exists $params stdin] ? [dict get $params stdin] : ""}]
	return [dict create result [rio::exec::run $argv $cwd $stdin]]
}
rio::dispatch::register exec.run rio::ops::exec_run
