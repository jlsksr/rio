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

namespace eval rio::exec {}

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
