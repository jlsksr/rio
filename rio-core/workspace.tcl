# rio-core — the per-project workspace store (D31).
#
# Which files were open in a project, which tab was active, which directories
# were unfolded. One file per project root, under the data dir on the core's
# host (D30): nothing is written into the repo.
#
# Not session.hello, which is the protocol's handshake.
#
# JSON, because the conf format (D21) cannot hold a list. No Tk, no protocol.

# tcllib, through the dependency gate (D116). Sourced here because a test
# sources this file alone.
source [file join [file dirname [info script]] deps.tcl]
rio::deps::require json
rio::deps::require json::write
rio::deps::require md5

namespace eval rio::workspace {
	variable override_dir ""   ;# tests point this at a temp dir; "" = real XDG path
}

# The sessions directory: $XDG_DATA_HOME/rio/sessions, default ~/.local/share/.
proc rio::workspace::_dir {} {
	variable override_dir
	if {$override_dir ne ""} { return $override_dir }
	if {[info exists ::env(XDG_DATA_HOME)] && $::env(XDG_DATA_HOME) ne ""} {
		set base $::env(XDG_DATA_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .local share]
	} else {
		set base [pwd]
	}
	return [file join $base rio sessions]
}

# One file per project, named by the md5 of the normalized root: short and
# safe for any path. The root is stored inside the file too, for a human
# reading the dir.
#
# The empty root is the anonymous session (D72): files open without a
# project. Its file is anonymous.json.
proc rio::workspace::_key {root} { return [md5::md5 -hex [file normalize $root]] }
proc rio::workspace::_path {root} {
	if {$root eq ""} { return [file join [_dir] anonymous.json] }
	return [file join [_dir] [_key $root].json]
}

# Save a project's session, replacing the earlier one.
#   open     — the open files' paths, in tab order
#   active   — the focused tab's path, or ""
#   expanded — the directories unfolded in the file tree (D89)
# An empty root is stored as "": normalizing it would give the cwd.
proc rio::workspace::save {root open active {expanded {}}} {
	set dir [_dir]
	file mkdir $dir
	catch {file attributes $dir -permissions 0700}
	set stored [expr {$root eq "" ? "" : [file normalize $root]}]
	set json [json::write object \
		root     [json::write string $stored] \
		active   [json::write string $active] \
		open     [json::write array {*}[lmap p $open {json::write string $p}]] \
		expanded [json::write array {*}[lmap p $expanded {json::write string $p}]]]
	set f [open [_path $root] {WRONLY CREAT TRUNC}]
	fconfigure $f -encoding utf-8
	puts -nonewline $f $json
	close $f
	return
}

# Read a project's session as {open <list> active <path> expanded <list>}.
# No file, or a corrupt one, reads as empty: a resume must not stop the
# editor from starting.
proc rio::workspace::get {root} {
	set path [_path $root]
	if {![file exists $path]} { return [dict create open {} active "" expanded {}] }
	if {[catch {
		set f [open $path r]
		fconfigure $f -encoding utf-8
		set text [::read $f]
		close $f
		set d [json::json2dict $text]
	}]} { return [dict create open {} active "" expanded {}] }
	set open     [expr {[dict exists $d open]     ? [dict get $d open]     : {}}]
	set active   [expr {[dict exists $d active]   ? [dict get $d active]   : ""}]
	set expanded [expr {[dict exists $d expanded] ? [dict get $d expanded] : {}}]
	return [dict create open $open active $active expanded $expanded]
}

# Drop a project's saved session.
proc rio::workspace::forget {root} { catch {file delete [_path $root]} ; return }
