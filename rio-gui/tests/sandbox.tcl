# rio-gui test sandbox (AGENTS.md D31).
#
# Booting rio-gui.tcl now READS and WRITES the user's real preferences
# ($XDG_CONFIG_HOME/rio/prefs.json) and per-project workspaces
# ($XDG_DATA_HOME/rio/sessions/) — persistence arrived with sessions & preferences.
# A test must never touch those (it would clobber the user's real config and leak
# state between runs), so every GUI test that boots the GUI sources THIS first: it
# redirects both XDG dirs to a throwaway path and removes it however the test exits.
#
# session.tcl manages its own temp XDG dirs (it inspects the files it writes) and so
# does not use this.

set _sbxch [file tempfile _sbxname] ; close $_sbxch ; file delete $_sbxname
set ::sandbox_dir $_sbxname.d
set ::env(XDG_CONFIG_HOME) [file join $::sandbox_dir config]
set ::env(XDG_DATA_HOME)   [file join $::sandbox_dir data]

# Rename so the cleanup runs before the real exit, whatever code path calls exit.
rename exit _sandbox_real_exit
proc exit {{code 0}} { catch {file delete -force $::sandbox_dir} ; _sandbox_real_exit $code }

# Install a repository-distributed editing mode into the sandbox drop-in dir, the
# way the Extensions window would (D41: the core ships windows-only; vi and emacs
# live in the extensions/ repository). Call BEFORE sourcing rio-gui.tcl so the
# boot-time modes_load picks it up as a user drop-in — exercising the real path.
proc sandbox_install_mode {name} {
	set src [file join [file dirname [info script]] .. .. extensions $name $name.tcl]
	set dst [file join $::env(XDG_CONFIG_HOME) rio modes]
	file mkdir $dst
	file copy -force $src [file join $dst $name.tcl]
}

# Focused-group handles for the editor split (AGENTS.md D33). The pre-split editor was
# a single widget: tests drove edits through the .ed.t proxy and introspected the real
# widget as ::rio_real_t. Both now resolve to whichever editor group has focus — the
# same concept, one level of indirection. Defined here (bodies run at call time, after
# rio-gui.tcl has loaded) so every suite that sources this keeps working unchanged.
proc ::rio_real_t {args} { [gw $::focus] {*}$args }        ;# the focused real widget
proc .ed.t        {args} { [gget $::focus path] {*}$args } ;# the focused edit proxy

# Throw away a fixture directory the way teardown MEANS it: close any tab still open on it
# first, then delete. A plain `file delete -force` leaves buffers pointing at files that no
# longer exist, and rio rightly asks the user about each one at the next stale check (D94) —
# which in a test is a modal with nobody to answer it. close_buffers_under is the app's own
# answer to the same situation (rio-gui.tcl, the fs Delete path); it clears `modified`
# first, so there is no save-before-closing prompt either. Bodies run at call time, like the
# two procs above, so this may be defined before rio-gui.tcl has loaded.
proc sandbox_drop_fixture {dir} {
	catch {close_buffers_under $dir}
	file delete -force $dir
}
