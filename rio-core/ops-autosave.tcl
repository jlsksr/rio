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
#   autosave.discard      {buffers} -> {discarded N}
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

# autosave.discard {buffers:[id...]} -> {discarded N}
# Throw away the recovery copies of these buffers: they hold changes someone has since
# decided to abandon, so they are no longer what a crash would need.
#
# It exists for one moment a frontend cannot express any other way. buffer.close already
# drops a copy, but a frontend that is QUITTING does not close its buffers — it asks whether
# to save each one and then goes. Answering "no" there IS a decision to discard, and without
# this the next launch would restore that file (D31) and offer back the very edits the user
# had just declined. The frontend decides when that has happened, because `modified` is its
# own state (D22); the core only does what it is told.
#
# It FORGETS each buffer rather than marking it written, which is the opposite move and the
# one that matters: a frontend that calls this and then keeps running still has unsaved
# changes, so the next sweep has to protect them again. Deleting the file alone would not do
# it — the sweep that wrote the copy had already recorded the buffer as written, so without
# the forget those buffers would sit unprotected until their next edit.
#
# A buffer with no file, or with no copy, is skipped rather than refused — a frontend naming
# its whole open set must not have to sort them first.
proc rio::ops::autosave_discard {params} {
	if {![dict exists $params buffers]} {
		rio::error::raise bad_request "autosave.discard requires buffers"
	}
	set n 0
	foreach id [dict get $params buffers] {
		if {![rio::doc::exists $id]} continue
		set meta [rio::doc::meta $id]
		if {![dict exists $meta path] || [dict get $meta path] eq ""} continue
		set ap [rio::autosave::path_for [dict get $meta path]]
		if {$ap eq "" || ![file exists $ap]} continue
		rio::autosave::discard $id
		rio::autosave::forget $id
		incr n
	}
	return [dict create result [dict create discarded $n]]
}
rio::dispatch::register autosave.discard rio::ops::autosave_discard
