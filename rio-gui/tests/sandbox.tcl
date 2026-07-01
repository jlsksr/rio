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
