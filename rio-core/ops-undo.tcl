# rio-core — the edit.* op namespace: undo/redo (AGENTS.md O3).
#
# Thin handlers over the document model's undo/redo. Each, when it changes
# anything, emits the SAME buffer.changed event a normal edit would (D3/D11) so
# every view resyncs through one generic path — undo is not special to a view, it
# is just another range replacement. When there is nothing to (un/re)do the op
# still succeeds, reporting changed=false and emitting no event.

proc rio::ops::_edit_step {id ch} {
	if {$ch eq ""} { return [dict create result [dict create changed false]] }
	set ev [dict create event buffer.changed params [dict create \
		buffer  $id \
		start   [dict get $ch start] \
		end     [dict get $ch end] \
		text    [dict get $ch text] \
		removed [dict get $ch removed]]]
	return [dict create result [dict create changed true] events [list $ev]]
}

# edit.undo {?buffer?} -> {changed} ; emits buffer.changed when it undid something.
proc rio::ops::edit_undo {params} {
	set id [_bufid $params]
	return [_edit_step $id [rio::doc::undo $id]]
}
rio::dispatch::register edit.undo rio::ops::edit_undo

# edit.redo {?buffer?} -> {changed} ; emits buffer.changed when it redid something.
proc rio::ops::edit_redo {params} {
	set id [_bufid $params]
	return [_edit_step $id [rio::doc::redo $id]]
}
rio::dispatch::register edit.redo rio::ops::edit_redo
