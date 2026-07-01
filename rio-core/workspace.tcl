# rio-core — the per-project workspace store (AGENTS.md D31).
#
# "Resume my working space": which files were open in a project, and which tab was
# active. Persisted PER PROJECT, keyed by the project root, OUT OF TREE under the
# data dir — never a file dropped into the repo (no git noise, nothing to
# .gitignore), and, being core-side, it follows the project onto the server in
# remote mode (D30), exactly like the files it names.
#
# Distinct from two neighbours that share the word "session":
#   - rio::secret   — credentials, also under the data dir but 0600 (D26).
#   - session.hello — the *protocol* handshake (O2), nothing to do with workspaces.
#
# Stored as JSON: the payload is a LIST of paths plus two scalars, and the flat
# "[section] key = value" conf format (D21) is last-wins per key, so it cannot hold
# the open-file list. Written with json::write, read with json::json2dict — both
# already required (the wire uses json). Pure: no Tk, no protocol; the op layer
# (ops-workspace) adds project-root keying and stale-path pruning.

package require json
package require json::write
package require md5

namespace eval rio::workspace {
	variable override_dir ""   ;# tests point this at a temp dir; "" = real XDG path
}

# The sessions directory: $XDG_DATA_HOME/rio/sessions (default ~/.local/share/...),
# the data-dir home for machine-written state (D21) — beside secrets/, apart from
# config/ (settings, themes).
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

# One file per project, named by a hash of the NORMALIZED root, so any root (deep,
# spaces, unicode) yields a short, collision-free, filesystem-safe key regardless
# of length. The root is also stored INSIDE the file, so the store is
# self-describing when a human inspects the dir.
proc rio::workspace::_key {root} { return [md5::md5 -hex [file normalize $root]] }
proc rio::workspace::_path {root} { return [file join [_dir] [_key $root].json] }

# Save a project's session. `open` is the list of file paths that were open (in
# tab order); `active` is the focused tab's path (may be "" or not in `open`).
# Creates the dir; overwrites any prior session for that root.
proc rio::workspace::save {root open active} {
	set dir [_dir]
	file mkdir $dir
	catch {file attributes $dir -permissions 0700}
	set json [json::write object \
		root   [json::write string [file normalize $root]] \
		active [json::write string $active] \
		open   [json::write array {*}[lmap p $open {json::write string $p}]]]
	set f [open [_path $root] {WRONLY CREAT TRUNC}]
	fconfigure $f -encoding utf-8
	puts -nonewline $f $json
	close $f
	return
}

# Read a project's session as {open <list> active <path>}, or {open {} active ""}
# for a first-time (or corrupt) project — a resume must never be what stops the
# editor from starting, so a bad file reads as empty rather than throwing.
proc rio::workspace::get {root} {
	set path [_path $root]
	if {![file exists $path]} { return [dict create open {} active ""] }
	if {[catch {
		set f [open $path r]
		fconfigure $f -encoding utf-8
		set text [::read $f]
		close $f
		set d [json::json2dict $text]
	}]} { return [dict create open {} active ""] }
	set open   [expr {[dict exists $d open]   ? [dict get $d open]   : {}}]
	set active [expr {[dict exists $d active] ? [dict get $d active] : ""}]
	return [dict create open $open active $active]
}

# Drop a project's saved session.
proc rio::workspace::forget {root} { catch {file delete [_path $root]} ; return }
