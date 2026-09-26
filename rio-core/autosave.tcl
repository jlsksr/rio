# rio-core — automatic recovery files (AGENTS.md D132).
#
# A buffer's edits live only in this process until someone saves: kill the core, lose the
# tunnel or pull the plug, and everything typed since the last save is gone. So every so
# often each CHANGED buffer is written to a copy of its own, which is deleted the moment
# that buffer is really saved and offered back the next time the file is opened.
#
# emacs's model, not VSCode's: the file you are editing is NEVER written without an
# explicit save. What this module writes is recovery data and nothing else — a save is
# still a save, and until you make one the bytes on disk are the ones you last put there.
#
# It lives in the core because the file does (D30). A frontend may be on another machine,
# where the project's path means nothing (D55), and a persistent daemon holds buffers with
# no frontend attached at all — so the policy has to be the core's, not something a client
# announces when it arrives. The frontend keeps only the toggle's mirror and the question.
#
# WHERE the copies go — out of the project tree, under $XDG_DATA_HOME/rio/autosave/, with
# the file's own directory mirrored below it:
#
#     /home/jka/Projekte/rio/rio-gui/rio-gui.tcl
#         -> ~/.local/share/rio/autosave/home/jka/Projekte/rio/rio-gui/#rio-gui.tcl#
#
# emacs writes `#rio-gui.tcl#` beside the file; rio keeps the name and moves the place, for
# the reason D31 moved session state out of the tree: it never shows in `git status`, needs
# no `.gitignore`, and cannot be committed by accident. Beside the file it would also have
# to be hidden from the files pane, from project search, from the agent's fs tools and from
# git's own porcelain — four copies of one rule. The mirrored path is readable on purpose:
# `ls -R` over the autosave root is a plain report of what is unsaved and where it belongs.
#
# WHAT COUNTS AS CHANGED is `rio::doc::revision` (D132), the document's own change counter
# — not a dirty flag, which is a view's word for how a buffer differs from disk and belongs
# to each frontend (D22). `saved` below holds the revision at this module's last write.
#
# Tk-free and protocol-free (D1): ops-autosave.tcl carries the ops, and the question a
# recovery file raises is the frontend's (D125 — the core states the fact, the frontend
# owns the question).

namespace eval rio::autosave {
	variable saved ; array set saved {}  ;# buffer id -> doc revision at the last write
	variable timer ""            ;# the pending tick, "" while none is armed
	variable default_interval 30000
	variable dir_override ""     ;# tests pin the autosave root here
	variable settings_override "" ;# tests pin autosave.conf here
}

# --- where things are -------------------------------------------------------------------

# The autosave root, on the CORE's host. With neither XDG_DATA_HOME nor HOME there is no
# root and no autosaving: unlike a session file, recovery data scattered through the
# current working directory would be worse than none at all.
proc rio::autosave::root {} {
	variable dir_override
	if {$dir_override ne ""} { return [file normalize $dir_override] }
	if {[info exists ::env(XDG_DATA_HOME)] && $::env(XDG_DATA_HOME) ne ""} {
		set base $::env(XDG_DATA_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .local share]
	} else {
		return ""
	}
	return [file normalize [file join $base rio autosave]]
}

# The mirrored segments for a directory, given what `file split` made of it: a RELATIVE
# list, always, because `file join /a /b` is "/b" — an absolute remainder would silently
# escape the autosave root and write over something real. Split out from `path_for` so
# every head shape is testable on any host: a Windows volume only ever comes back from a
# `file split` running on Windows.
proc rio::autosave::_mirror_parts {parts} {
	set head [lindex $parts 0]
	set rest [lrange $parts 1 end]
	if {[regexp {^([A-Za-z]):[/\\]?$} $head -> drv]} {
		return [linsert $rest 0 $drv]              ;# a volume: "C:/" -> "C"
	}
	if {$head eq "/" || $head eq "\\" || $head eq ""} {
		return $rest                               ;# the ordinary POSIX absolute path
	}
	# Anything else — a UNC "//server/share" head, a volume-relative oddity — is flattened
	# into ONE segment rather than trusted to stay relative.
	return [linsert $rest 0 [string map {/ _ \\ _ : _} $head]]
}

# The recovery file for a document path, or "" when there can be none.
#
# Built from `file split`, never string surgery, because `file join /a /b` is "/b": an
# absolute remainder — a Windows drive, a UNC share — would silently escape the root and
# write over something real. Every head a split can hand back becomes exactly one readable
# segment, and the result is checked to sit under the root before it is returned.
proc rio::autosave::path_for {file} {
	if {$file eq ""} { return "" }
	set r [root]
	if {$r eq ""} { return "" }
	set abs [file normalize $file]
	set tail [file tail $abs]
	if {$tail eq ""} { return "" }
	set parts [_mirror_parts [file split [file dirname $abs]]]
	set p [file join $r {*}$parts "#$tail#"]
	if {[string first "$r/" "$p/"] != 0} { return "" }
	return $p
}

# --- the setting: autosave.conf (D21 format, parsed never executed) ---------------------
#
# $XDG_CONFIG_HOME/rio/autosave.conf, beside tls.conf, top-level keys:
#     autosave    = on|off        (default ON)
#     interval_ms = 30000         (minimum 1000)
# Absent, unreadable, malformed, or any value but a plain no — "off", "0", "no", "false",
# whatever the case — leaves autosave ON. That is
# the opposite of tls.conf's fail-closed rule and deliberately so: there the safe side is
# refusing a connection, here it is protecting work the user has not saved.
proc rio::autosave::settings_path {} {
	variable settings_override
	if {$settings_override ne ""} { return $settings_override }
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		return [file join $::env(XDG_CONFIG_HOME) rio autosave.conf]
	} elseif {[info exists ::env(HOME)]} {
		return [file join $::env(HOME) .config rio autosave.conf]
	}
	return ""
}

# One top-level key, or "" for every way there is no answer. Read on each call, so a hand
# edit counts at the next tick with no restart (tls.conf's habit, same reason).
proc rio::autosave::_conf {key} {
	set p [settings_path]
	if {$p eq "" || ![file isfile $p] || ![llength [info commands ::rio::conf::read_file]]} {
		return ""
	}
	if {[catch {::rio::conf::read_file $p} conf]} { return "" }
	if {![dict exists $conf "" $key]} { return "" }
	return [dict get $conf "" $key]
}

proc rio::autosave::enabled {} {
	set v [string tolower [string trim [_conf autosave]]]
	if {$v eq ""} { return 1 }
	return [expr {$v ni {off 0 no false}}]
}

proc rio::autosave::interval {} {
	variable default_interval
	set v [string trim [_conf interval_ms]]
	if {![string is integer -strict $v]} { return $default_interval }
	if {$v < 1000} { return 1000 }
	return $v
}

# Turn it on or off. The interval is read BEFORE the rewrite and written back, so ticking
# the box never silently discards a hand-tuned one.
proc rio::autosave::set_enabled {on} {
	set on [expr {$on ? 1 : 0}]
	set p [settings_path]
	if {$p eq ""} { error "no config directory: neither XDG_CONFIG_HOME nor HOME is set" }
	set ms [interval]
	file mkdir [file dirname $p]
	set fh [open $p w]
	fconfigure $fh -encoding utf-8
	puts $fh "# rio — automatic recovery files for unsaved changes (AGENTS.md D132)."
	puts $fh "# rio NEVER writes the file you are editing without a save: this is about the"
	puts $fh "# separate copy it keeps under \$XDG_DATA_HOME/rio/autosave/ so a crash costs you"
	puts $fh "# at most one interval, and offers back the next time you open that file."
	puts $fh "#"
	puts $fh "# autosave = off turns that off. Anything else — another value, a typo, no file at"
	puts $fh "# all — leaves it ON: the safe side here is protecting work, not withholding it."
	puts $fh "# interval_ms = how often a changed buffer is written (minimum 1000)."
	puts $fh "autosave = [expr {$on ? "on" : "off"}]"
	puts $fh "interval_ms = $ms"
	close $fh
	return $on
}

# --- bookkeeping ------------------------------------------------------------------------

# "I have written this buffer" — after an autosave, a real save, an open, a reload or a
# recovery, all of which leave the copy (or the file) matching the buffer.
proc rio::autosave::note_saved {id} {
	variable saved
	if {[catch {rio::doc::revision $id} r]} return
	set saved($id) $r
}

proc rio::autosave::forget {id} {
	variable saved
	unset -nocomplain saved($id)
}

# A buffer nobody has noted counts as changed: better one needless copy than none.
proc rio::autosave::dirty {id} {
	variable saved
	if {![info exists saved($id)]} { return 1 }
	if {[catch {rio::doc::revision $id} r]} { return 0 }
	return [expr {$r != $saved($id)}]
}

# --- writing and discarding -------------------------------------------------------------

# Write one buffer's recovery copy; 1 if it was written, 0 if there was nowhere to put it.
# The buffer's own meta goes to rio::fs::write, so the copy reproduces the file's encoding,
# BOM and line endings (D22) — recovery hands back what a save would have made.
proc rio::autosave::write_one {id} {
	set meta [rio::doc::meta $id]
	if {![dict exists $meta path] || [dict get $meta path] eq ""} { return 0 }
	set ap [path_for [dict get $meta path]]
	if {$ap eq ""} { return 0 }
	file mkdir [file dirname $ap]
	rio::fs::write $ap [rio::doc::text $id] $meta
	note_saved $id
	return 1
}

proc rio::autosave::discard {id} {
	if {[catch {rio::doc::meta $id} meta]} return
	if {![dict exists $meta path]} return
	discard_path [dict get $meta path]
}

proc rio::autosave::discard_path {file} {
	if {$file eq ""} return
	set ap [path_for $file]
	if {$ap eq "" || ![file exists $ap]} return
	catch {file delete -- $ap}
	# Tidy the mirror directory if that was the last copy in it, so the root stays a
	# readable report of what is unsaved. `file delete` refuses a non-empty directory, so
	# the catch IS the emptiness check. One level only, and never the root itself.
	set parent [file dirname $ap]
	if {$parent ne [root]} { catch {file delete -- $parent} }
	return
}

# --- what a file has waiting for it -----------------------------------------------------

# {path mtime newer} for a document path with a recovery copy, or {} for none.
#
# A copy OLDER than the file is still reported. It can hold work the file never had — a
# `git checkout` or another editor landed on top of it — so hiding it, or deleting it as
# spent, would be the lie. `newer` lets the frontend say which way round it is; a file
# that has since vanished leaves the copy as the only text there is, so: newer.
proc rio::autosave::recovery_for {file} {
	set ap [path_for $file]
	if {$ap eq "" || ![file isfile $ap]} { return {} }
	if {[catch {file mtime $ap} am]} { return {} }
	set fm ""
	catch {set fm [file mtime $file]}
	set newer [expr {![string is integer -strict $fm] || $am > $fm}]
	return [dict create path $ap mtime $am newer [expr {$newer ? 1 : 0}]]
}

# --- the timer --------------------------------------------------------------------------

# Write every changed buffer that has a file. Returns how many were written. A failure —
# a read-only directory, a full disk, a path the host cannot take — skips that buffer and
# nothing more: it must not raise into the event loop or take the timer down with it.
proc rio::autosave::sweep {} {
	set n 0
	foreach b [rio::doc::inventory] {
		set id [dict get $b buffer]
		if {[dict get $b path] eq ""} continue
		if {![dirty $id]} continue
		if {[catch {write_one $id} wrote]} continue
		incr n $wrote
	}
	return $n
}

# rio's first RECURRING timer in the core; every other `after` here is one-shot. Started by
# server.tcl on the direct-execution path only, so a test that sources it gets a core with
# no timer and drives `sweep` itself.
#
# It needs none of the guards the frontend's deferred work carries (::pending,
# fs_changed_settle): a sweep dispatches no op, emits no event and touches no channel, so
# it is safe wherever the event loop reaches it — a nested vwait in rio::http included.
proc rio::autosave::start {} {
	variable timer
	stop
	set timer [after [interval] rio::autosave::_tick]
	return
}

proc rio::autosave::stop {} {
	variable timer
	if {$timer ne ""} { after cancel $timer ; set timer "" }
	return
}

# The setting and the interval are re-read every tick, so the toggle and a hand edit both
# take effect at the next one — and turning autosave off leaves the timer running, so
# turning it back on needs no restart either.
proc rio::autosave::_tick {} {
	variable timer
	set timer ""
	if {[enabled]} { catch {sweep} }
	set timer [after [interval] rio::autosave::_tick]
	return
}
