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
#
# The empty root is the ANONYMOUS session (D72): the files open with no project — a
# loose "daily workspace" that spans folders and so has no common root to key by. It
# gets a reserved literal filename; that can't collide with a real root's key, which
# is always 32 hex chars of md5.
proc rio::workspace::_key {root} { return [md5::md5 -hex [file normalize $root]] }
proc rio::workspace::_path {root} {
	if {$root eq ""} { return [file join [_dir] anonymous.json] }
	return [file join [_dir] [_key $root].json]
}

# Save a project's session. `open` is the list of file paths that were open (in
# tab order); `active` is the focused tab's path (may be "" or not in `open`);
# `expanded` is the set of directories unfolded in the file tree (D89), an
# unordered list. An empty root is the anonymous session (D72) — stored verbatim,
# not normalized (which would turn "" into the cwd), keeping the self-describing
# `root` field empty. Creates the dir; overwrites any prior session for that root.
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

# Read a project's session as {open <list> active <path> expanded <list>}, or all
# empty for a first-time (or corrupt) project — a resume must never be what stops the
# editor from starting, so a bad file reads as empty rather than throwing. `expanded`
# defaults empty so a session written before D89 (no such key) reads back cleanly.
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
