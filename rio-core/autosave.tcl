# rio-core — automatic recovery files (D132).
#
# Edits live only in this process until a save. So every interval each changed
# buffer is written to a recovery copy. The copy is deleted when the buffer is
# saved and offered back when the file is next opened.
#
# - The file being edited is never written without a save (emacs's model).
# - In the core, because the file is there (D30) and a daemon may hold buffers
#   with no frontend attached.
# - The copies are outside the project, so git, search and the files pane
#   never see them. The file's directory is mirrored under the root:
#
#     /home/jka/Projekte/rio/rio-gui/rio-gui.tcl
#         -> ~/.local/share/rio/autosave/home/jka/Projekte/rio/rio-gui/#rio-gui.tcl#
#
# - "Changed" is `rio::doc::revision`, not a frontend's dirty flag (D22).
#   `saved` holds the revision at the last write.
#
# No Tk, no protocol: the ops are in ops-autosave.tcl.

namespace eval rio::autosave {
	variable saved ; array set saved {}  ;# buffer id -> doc revision at the last write
	variable timer ""            ;# the pending tick, "" while none is armed
	variable default_interval 30000
	variable dir_override ""     ;# tests pin the autosave root here
	variable settings_override "" ;# tests pin autosave.conf here
}

# --- where things are -------------------------------------------------------------------

# The autosave root, on the core's host. Without XDG_DATA_HOME and HOME there
# is none, and no autosaving.
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

# The mirrored segments for a directory, from its `file split`. Always
# relative: `file join /a /b` is "/b", so an absolute part would escape the
# root.
#   {/ home jka}  -> {home jka}
#   {C:/ Users}   -> {C Users}
# Its own proc, so a Windows head is testable on any host.
proc rio::autosave::_mirror_parts {parts} {
	set head [lindex $parts 0]
	set rest [lrange $parts 1 end]
	if {[regexp {^([A-Za-z]):[/\\]?$} $head -> drv]} {
		return [linsert $rest 0 $drv]              ;# a volume: "C:/" -> "C"
	}
	if {$head eq "/" || $head eq "\\" || $head eq ""} {
		return $rest                               ;# the ordinary POSIX absolute path
	}
	# Anything else, e.g. a UNC "//server/share", becomes one segment.
	return [linsert $rest 0 [string map {/ _ \\ _ : _} $head]]
}

# The recovery file for a document path, or "" when there can be none. The
# result is checked to sit under the root.
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
# Only off, 0, no or false (any case) turns it off. Absent or malformed
# leaves it on: the safe side is protecting unsaved work.
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

# One top-level key, or "". Read on each call, so a hand edit needs no restart.
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

# Turn it on or off. The interval is read first and written back, so a
# hand-set one survives.
proc rio::autosave::set_enabled {on} {
	set on [expr {$on ? 1 : 0}]
	set p [settings_path]
	if {$p eq ""} { error "no config directory: neither XDG_CONFIG_HOME nor HOME is set" }
	set ms [interval]
	file mkdir [file dirname $p]
	set fh [open $p w]
	fconfigure $fh -encoding utf-8
	puts $fh "# rio — automatic recovery files for unsaved changes (D132)."
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

# Record that the buffer matches its copy or its file: after an autosave, a
# save, an open, a reload or a recovery.
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

# Write one buffer's recovery copy; 1 if written, 0 if there is no place for
# it. Written with the buffer's meta, so the copy is what a save would make
# (D22).
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
	# Remove the mirror directory if it is now empty: `file delete` refuses a
	# non-empty one. One level only, never the root.
	set parent [file dirname $ap]
	if {$parent ne [root]} { catch {file delete -- $parent} }
	return
}

# --- what a file has waiting for it -----------------------------------------------------

# {path mtime newer} for a document path with a recovery copy, or {} for none.
#
# A copy older than the file is still reported: it may hold work the file
# never had. `newer` says which way round it is; with the file gone, 1.
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

# Write every changed buffer that has a file. Returns how many were written.
# A failure (read-only directory, full disk) skips that buffer only.
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

# Start the recurring timer. server.tcl calls this only when run directly, so
# a test that sources the core has no timer and calls `sweep` itself.
# A sweep dispatches no op and emits no event, so it is safe anywhere in the
# event loop, a nested vwait included.
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

# Setting and interval are read every tick. Off leaves the timer running, so
# on again needs no restart.
proc rio::autosave::_tick {} {
	variable timer
	set timer ""
	if {[enabled]} { catch {sweep} }
	set timer [after [interval] rio::autosave::_tick]
	return
}
