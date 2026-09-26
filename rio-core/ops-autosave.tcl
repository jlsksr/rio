# rio-core — the autosave.* op namespace (AGENTS.md D132).
#
# The core keeps a recovery copy of every changed buffer (rio::autosave). These two ops are
# how a frontend reads that policy and sets it. The policy is the CORE's, not a client's:
# the copies land on the core's disk, which may be another machine (D30), and a persistent
# daemon autosaves buffers with no frontend attached at all — so it cannot wait to be told
# what to do when one arrives. A frontend mirrors what it is told and writes only when the
# user asks, the habit agent.status and tls.settings already have.
#
#   autosave.settings     {}        -> {enabled interval}
#   autosave.settings.set {enabled} -> {enabled interval}
#
# The setter answers with what the setting READS BACK AS, not with what it was handed, so a
# frontend's control can only ever show what the core actually holds.
#
# Flat results, so the default wire encoder carries them; anything nested here would need a
# registered shape (D25), and a key the encoder does not name never reaches the wire at all
# (D123) — the trap to remember if these grow.
#
# Recovering ONE buffer's copy is buffers.recover, in ops-buffer.tcl beside the reload it is
# shaped after.

proc rio::ops::_autosave_state {} {
	return [dict create enabled [rio::autosave::enabled] interval [rio::autosave::interval]]
}

proc rio::ops::autosave_settings {params} {
	return [dict create result [_autosave_state]]
}
rio::dispatch::register autosave.settings rio::ops::autosave_settings

proc rio::ops::autosave_settings_set {params} {
	if {![dict exists $params enabled]} {
		rio::error::raise bad_request "autosave.settings.set requires enabled"
	}
	set v [dict get $params enabled]
	if {![string is boolean -strict $v]} {
		rio::error::raise bad_request \
			"autosave.settings.set: enabled must be a boolean, got: $v"
	}
	if {[catch {rio::autosave::set_enabled $v} err]} {
		rio::error::raise io_error "couldn't write the autosave setting: $err"
	}
	return [dict create result [_autosave_state]]
}
rio::dispatch::register autosave.settings.set rio::ops::autosave_settings_set
