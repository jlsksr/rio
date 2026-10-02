# rio-core — the command-execution primitive (D15).
#
# Run an external command and capture its stdout, stderr and exit code. git
# (D7) and the agent (D20) build on it. rio has no terminal pane (D15).
#
# - The command is an argv, never a shell string: no shell, no quoting, no
#   injection, and the same on Windows.
# - Tcl's exec still reads an argv element like ">" as a redirection. The
#   agent's path refuses those (rio::agent::tools::_is_redirection).
# - `run` blocks until the child exits: for short commands such as git's.
#   `start` does not block: for the agent's run_command.

namespace eval rio::exec {
	variable _tok  0    ;# monotonic token source for start/cancel (D83)
	variable _jobs      ;# array: token -> in-flight state dict
	array set _jobs {}
}

proc rio::exec::_slurp {path} {
	# The bytes as they are: no EOL translation, no decoding.
	set f [open $path rb]
	set d [::read $f]
	close $f
	return $d
}

# rio::exec::run argv ?cwd? ?stdin? -> {exitcode <int> stdout <s> stderr <s>}
#
# A non-zero exit is not an error: the code is data. Only a failed launch
# (no such program, bad cwd) raises io_error. A child killed by a signal
# reports exitcode -1.
proc rio::exec::run {argv {cwd ""} {stdin ""}} {
	if {[llength $argv] == 0} {
		rio::error::raise bad_request "exec.run requires a non-empty argv"
	}
	set restore ""
	if {$cwd ne ""} {
		if {![file isdirectory $cwd]} {
			rio::error::raise io_error "no such directory: $cwd"
		}
		set restore [pwd]
	}
	# Both streams go to temp files: the exit code then comes from -errorcode
	# alone, and stderr output is not taken for an error. Single-threaded, so
	# cd and back around the spawn is safe.
	set outf [file tempfile outpath] ; close $outf
	set errf [file tempfile errpath] ; close $errf
	set exitcode 0
	if {$restore ne ""} { cd $cwd }
	set rc [catch {exec -- {*}$argv << $stdin > $outpath 2> $errpath} msg opts]
	if {$restore ne ""} { cd $restore }
	if {$rc} {
		set ec [dict get $opts -errorcode]
		switch -- [lindex $ec 0] {
			CHILDSTATUS { set exitcode [lindex $ec 2] }
			CHILDKILLED { set exitcode -1 }
			NONE        { set exitcode 0 }
			default {
				# Not a ran-and-failed command — the spawn itself failed.
				file delete $outpath $errpath
				rio::error::raise io_error $msg
			}
		}
	}
	set out [_slurp $outpath]
	set err [_slurp $errpath]
	file delete $outpath $errpath
	return [dict create exitcode $exitcode stdout $out stderr $err]
}

# --- async spawn (D83) --------------------------------------------
#
# rio::exec::start {argv cwd stdin timeout_ms donecmd} -> token
#
# `run` without blocking: a long child must not freeze the core. Spawns the
# child, returns at once, reads its stdout off a pipe, and when it exits calls
#   {*}$donecmd {exitcode <int> stdout <s> stderr <s> timedout <0|1> ?error <msg>?}
# No shell, as in run.
#
# - timeout_ms > 0: a watchdog kills the child and sets `timedout`.
# - The token is for `cancel`, which kills the job without calling donecmd.
proc rio::exec::start {argv cwd stdin timeout_ms donecmd} {
	variable _tok
	variable _jobs
	if {[llength $argv] == 0} {
		rio::error::raise bad_request "exec.run requires a non-empty argv"
	}
	if {$cwd ne "" && ![file isdirectory $cwd]} {
		rio::error::raise io_error "no such directory: $cwd"
	}
	set errf [file tempfile errpath] ; close $errf
	set save ""
	if {$cwd ne ""} { set save [pwd] ; cd $cwd }
	set rc [catch {open [list | {*}$argv << $stdin 2> $errpath] r} chan]
	if {$save ne ""} { cd $save }
	set tok [incr _tok]
	if {$rc} {
		# The pipe failed to open. Report it with `after 0`: donecmd is never
		# called inline.
		file delete $errpath
		after 0 [list {*}$donecmd [dict create exitcode -1 stdout "" stderr "" \
			timedout 0 error $chan]]
		return $tok
	}
	fconfigure $chan -blocking 0 -translation binary
	set wd ""
	if {$timeout_ms > 0} { set wd [after $timeout_ms [list rio::exec::_watchdog $tok]] }
	set _jobs($tok) [dict create chan $chan errpath $errpath out "" \
		timedout 0 watchdog $wd done $donecmd]
	fileevent $chan readable [list rio::exec::_readable $tok]
	return $tok
}

# The pipe is readable: take what is there; finish on EOF.
proc rio::exec::_readable {tok} {
	variable _jobs
	if {![info exists _jobs($tok)]} return
	set chan [dict get $_jobs($tok) chan]
	append cur [dict get $_jobs($tok) out] [read $chan]
	dict set _jobs($tok) out $cur
	if {[eof $chan]} { _finish $tok }
}

# The child overran its timeout: mark it and kill it. The EOF that follows
# runs _finish.
proc rio::exec::_watchdog {tok} {
	variable _jobs
	if {![info exists _jobs($tok)]} return
	dict set _jobs($tok) timedout 1
	catch {_kill [pid [dict get $_jobs($tok) chan]]}
}

# The child exited: cancel the watchdog, take the exit code from close, read
# stderr, call donecmd. A second call is a no-op.
proc rio::exec::_finish {tok} {
	variable _jobs
	if {![info exists _jobs($tok)]} return
	set st $_jobs($tok)
	unset _jobs($tok)
	if {[dict get $st watchdog] ne ""} { after cancel [dict get $st watchdog] }
	set chan [dict get $st chan]
	fileevent $chan readable {}
	# Blocking again: only a blocking close reports the exit status. The child
	# is at EOF, so it does not wait.
	fconfigure $chan -blocking 1
	set exitcode 0 ; set error ""
	set rc [catch {close $chan} msg opts]
	if {$rc} {
		set ec [dict get $opts -errorcode]
		switch -- [lindex $ec 0] {
			CHILDSTATUS { set exitcode [lindex $ec 2] }
			CHILDKILLED { set exitcode -1 }
			NONE        { set exitcode 0 }
			default     { set exitcode -1 ; set error $msg }
		}
	}
	set err [_slurp [dict get $st errpath]]
	file delete [dict get $st errpath]
	set res [dict create exitcode $exitcode stdout [dict get $st out] \
		stderr $err timedout [dict get $st timedout]]
	if {$error ne ""} { dict set res error $error }
	{*}[dict get $st done] $res
}

# Kill a running job and forget it. donecmd is not called. For a turn
# aborted while its command runs.
proc rio::exec::cancel {tok} {
	variable _jobs
	if {![info exists _jobs($tok)]} return
	set st $_jobs($tok)
	unset _jobs($tok)
	if {[dict get $st watchdog] ne ""} { after cancel [dict get $st watchdog] }
	catch {_kill [pid [dict get $st chan]]}
	catch {fileevent [dict get $st chan] readable {}}
	catch {close [dict get $st chan]}
	catch {file delete [dict get $st errpath]}
}

# Kill children by pid. Tcl 8.6 has no kill: `kill -TERM` on unix, `taskkill
# /T` (the whole tree) on Windows. A child already gone is ignored.
proc rio::exec::_kill {pids} {
	foreach p $pids {
		if {$::tcl_platform(platform) eq "windows"} {
			catch {exec taskkill /F /T /PID $p}
		} else {
			catch {exec kill -TERM $p}
		}
	}
}
