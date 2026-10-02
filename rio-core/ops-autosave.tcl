# rio-core — the autosave.* op namespace (D132).
#
# The autosave policy is the core's (rio::autosave); a frontend reads it and
# sets it.
#
#   autosave.settings     {}        -> {enabled interval}
#   autosave.settings.set {enabled} -> {enabled interval}
#   autosave.discard      {buffers} -> {discarded N}
#
# The setter answers with what the setting reads back as. Taking one buffer's
# copy is buffers.recover, in ops-buffer.tcl.

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
# Throw away these buffers' recovery copies. For a frontend that quits and
# was told "don't save": it closes no buffer, so without this the next launch
# would offer the declined edits back.
# - Each buffer is forgotten, not marked written: if the frontend keeps
#   running, the next sweep protects its unsaved changes again.
# - A buffer without a file or a copy is skipped.
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
