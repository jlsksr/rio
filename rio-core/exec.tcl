# rio-core — the command-execution primitive (AGENTS.md D15).
#
# Run an external command to completion and capture its stdout, stderr, and exit
# code. This is the headless plumbing git (D7) and the agent (D20) build on. rio
# has NO terminal pane (D15), so this never renders — output surfaces in whatever
# flow asked for it (e.g. the agent reacting to a failed test in `chat`).
#
# The command is an ARGUMENT VECTOR (argv), never a shell string: rio spawns the
# program directly with no shell, so there is no quoting or injection surface and
# the call behaves the same on Windows (no /bin/sh). That argv discipline is the
# baseline guardrail; richer policy — allow-lists, agent confirmation, and
# removing the residual exec redirection-token surface (an argv element literally
# ">" is still reserved by Tcl's exec) — is the agent-era work deferred under
# O4/D20.
#
# Synchronous: it blocks until the child exits. That suits short commands (git
# status / diff / log) — the pre-spike need. Streaming a long-running command's
# output as events over time needs the event-loop / coroutine model (D10) and
# lands with the rendering-heavy era; see O2's exec note.

namespace eval rio::exec {
	variable _tok  0    ;# monotonic token source for start/cancel (D83)
	variable _jobs      ;# array: token -> in-flight state dict
	array set _jobs {}
}

proc rio::exec::_slurp {path} {
	# Faithful bytes: no EOL translation, no re-encoding (matches the D22 ethos).
	# An encoding policy (like rio::fs's detection) can refine this later.
	set f [open $path rb]
	set d [::read $f]
	close $f
	return $d
}

# rio::exec::run argv ?cwd? ?stdin? -> {exitcode <int> stdout <s> stderr <s>}
#
# A command that runs and exits non-zero is a SUCCESS here (it ran); the exit
# code is data. Only a failure to LAUNCH (no such executable, unreadable cwd)
# raises — the op layer maps that to io_error. A child killed by a signal reports
# exitcode -1 (its message, if any, is on stderr).
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
	# Redirect BOTH streams to temp files so exec's own return value is unused:
	# the exit code comes solely from -errorcode, and redirecting stderr also
	# stops exec from treating stderr output as an error (its NONE case). Tcl is
	# single-threaded, so cd/restore around the spawn is safe.
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

# --- async spawn (AGENTS.md D83) --------------------------------------------
#
# rio::exec::start {argv cwd stdin timeout_ms donecmd} -> token
#
# The NON-BLOCKING sibling of run, for the agent's run-command tool. run blocks
# the whole (single-threaded) core until the child exits — fine for git's short
# commands, but the agent may run anything, so a long child would freeze the core
# and every frontend on it, and an `after`-based timeout could never fire while the
# interpreter sat blocked in `exec`. start spawns the child, returns immediately,
# reads its stdout off a pipe as it arrives, and calls `donecmd` with
#   {exitcode <int> stdout <s> stderr <s> timedout <0|1> ?error <msg>?}
# when the child exits (or the watchdog kills it). The event loop stays live
# throughout. Same argv discipline as run (NO shell); stderr is captured to a temp
# file and the exit code comes from close's -errorcode, exactly as run does.
#
# timeout_ms > 0 arms a watchdog that kills the child and marks `timedout`; a
# normal exit cancels it. A signal-killed child reports exitcode -1 (as run).
# The returned token feeds cancel, which tears the job down silently (no donecmd) —
# used when a turn is reset/sealed while its command is still running.
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
		# Rare: the pipe failed to open (most launch failures surface at close).
		# Report it asynchronously so the contract holds — donecmd always fires
		# on the event loop, never inline.
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

# Pipe became readable: drain what's available; finish on EOF. Non-blocking read
# returns "" at EOF with eof set (so we never block the loop).
proc rio::exec::_readable {tok} {
	variable _jobs
	if {![info exists _jobs($tok)]} return
	set chan [dict get $_jobs($tok) chan]
	append cur [dict get $_jobs($tok) out] [read $chan]
	dict set _jobs($tok) out $cur
	if {[eof $chan]} { _finish $tok }
}

# The watchdog: the child overran its timeout. Mark it and kill it; the ensuing
# EOF drives _finish (which reports exitcode -1 for the killed child).
proc rio::exec::_watchdog {tok} {
	variable _jobs
	if {![info exists _jobs($tok)]} return
	dict set _jobs($tok) timedout 1
	catch {_kill [pid [dict get $_jobs($tok) chan]]}
}

# Child exited: cancel the watchdog, read the exit code off close (same mapping as
# run), slurp stderr, and hand the capture to donecmd. Idempotent via the _jobs
# guard (a late readable after finish is a no-op).
proc rio::exec::_finish {tok} {
	variable _jobs
	if {![info exists _jobs($tok)]} return
	set st $_jobs($tok)
	unset _jobs($tok)
	if {[dict get $st watchdog] ne ""} { after cancel [dict get $st watchdog] }
	set chan [dict get $st chan]
	fileevent $chan readable {}
	# Back to blocking so close reaps the child and reports its exit status via
	# -errorcode; a non-blocking close returns early with no status. The child has
	# already reached EOF on stdout, so this doesn't actually block.
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

# Tear a running job down silently — kill the child, drop the watchdog and the
# channel, invoke NO donecmd. For reset/seal aborting a turn mid-command.
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

# Kill a child by pid. No portable Tcl primitive (8.6), so shell out: SIGTERM on
# unix, taskkill on Windows (/T so a process tree goes too). Best-effort — a child
# that already exited is a harmless error we swallow. (Windows kill fidelity: log
# any quirk in CAVEATS.)
proc rio::exec::_kill {pids} {
	foreach p $pids {
		if {$::tcl_platform(platform) eq "windows"} {
			catch {exec taskkill /F /T /PID $p}
		} else {
			catch {exec kill -TERM $p}
		}
	}
}
