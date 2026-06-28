# rio-core — the secrets store (AGENTS.md D21, D26).
#
# Tokens and credentials (e.g. the Claude API key, D26) are kept OUT of both the
# plain-text settings file and the synced session JSON, in their own files under
# the data dir with restrictive perms (0600). They are machine-written, never
# hand-edited, and must not ride along in a diff-friendly config a user might
# commit or sync. (OS keychain integration is a later refinement.)
#
# A secret is a flat set of key=value pairs (one provider's token set), stored in
# the same plain "[section]/key = value" format the rest of rio uses (rio::conf)
# — parsed, never executed — under the top-level section. Pure: no Tk.
#
# The proc names deliberately avoid `set`/`read`/`load` so they cannot shadow the
# Tcl builtins inside this namespace (cf. rio::fs's ::read discipline).

namespace eval rio::secret {
	variable override_dir ""   ;# tests point this at a temp dir; "" = real XDG path
}

# The secrets directory: $XDG_DATA_HOME/rio/secrets (default ~/.local/share/...),
# per D21's data-dir locations — distinct from config (settings/themes) and from
# session state.
proc rio::secret::_dir {} {
	variable override_dir
	if {$override_dir ne ""} { return $override_dir }
	if {[info exists ::env(XDG_DATA_HOME)] && $::env(XDG_DATA_HOME) ne ""} {
		set base $::env(XDG_DATA_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .local share]
	} else {
		set base [pwd]
	}
	return [file join $base rio secrets]
}

proc rio::secret::_path {name} { return [file join [_dir] $name.secret] }

# Write a secret (a flat dict of string values), creating the dir and file with
# tight perms. Overwrites any existing secret of that name.
proc rio::secret::save {name data} {
	set dir [_dir]
	file mkdir $dir
	catch {file attributes $dir -permissions 0700}
	set path [_path $name]
	set f [open $path {WRONLY CREAT TRUNC} 0600]
	fconfigure $f -encoding utf-8
	dict for {k v} $data { puts $f "$k = $v" }
	close $f
	catch {file attributes $path -permissions 0600}   ;# force, despite umask
	return
}

# Read a secret as a flat dict, or {} if there is none.
proc rio::secret::get {name} {
	set path [_path $name]
	if {![file exists $path]} { return {} }
	set conf [rio::conf::read_file $path]
	return [expr {[dict exists $conf ""] ? [dict get $conf ""] : {}}]
}

proc rio::secret::has {name} { return [file exists [_path $name]] }

# Delete a secret (e.g. when the user clears a stored API key).
proc rio::secret::forget {name} { catch {file delete [_path $name]} ; return }
