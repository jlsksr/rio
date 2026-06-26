# rio-core — the buffer.* op namespace (AGENTS.md D11, D12).
#
# Thin handlers that bridge the protocol to the document model. They hold no
# logic of their own beyond picking a target buffer and shaping events; the
# real work lives in rio::doc.

namespace eval rio::ops {
	variable default ""   ;# id of the buffer used when a request omits `buffer`
}

proc rio::ops::_bufid {params} {
	variable default
	if {[dict exists $params buffer]} { return [dict get $params buffer] }
	return $default
}

# buffer.new {?name?} -> {buffer, name} ; mints an empty buffer (a scratch tab).
proc rio::ops::buffer_new {params} {
	set name [expr {[dict exists $params name] ? [dict get $params name] : "untitled"}]
	set id [rio::doc::new "" $name]
	return [dict create result [dict create buffer $id name $name]]
}
rio::dispatch::register buffer.new rio::ops::buffer_new

# buffer.close {?buffer?} -> {} ; forgets a buffer (closing its tab).
proc rio::ops::buffer_close {params} {
	set id [_bufid $params]
	if {![rio::doc::exists $id]} { rio::error::raise no_buffer "no such buffer: $id" }
	rio::doc::close $id
	return [dict create result {}]
}
rio::dispatch::register buffer.close rio::ops::buffer_close

# buffer.list -> {buffers <array of {buffer,name,path,linecount}>}
# The core's inventory of open buffers, in creation order. This is the first op
# whose result is non-flat — `buffers` is an array — so the wire encoder is told
# the shape rather than guessing it (D25); see rio::wire.
proc rio::ops::buffer_list {params} {
	return [dict create result [dict create buffers [rio::doc::inventory]]]
}
rio::dispatch::register buffer.list rio::ops::buffer_list

# buffer.text -> {text <whole document>}
proc rio::ops::buffer_text {params} {
	return [dict create result [dict create text [rio::doc::text [_bufid $params]]]]
}
rio::dispatch::register buffer.text rio::ops::buffer_text

# buffer.replace {start, end, text} -> {} ; emits buffer.changed to all views.
proc rio::ops::buffer_replace {params} {
	set id [_bufid $params]
	set start [dict get $params start]
	set end   [dict get $params end]
	set text  [dict get $params text]
	set removed [rio::doc::edit $id $start $end $text]   ;# recorded for undo (O3)
	set ev [dict create event buffer.changed params \
		[dict create buffer $id start $start end $end text $text removed $removed]]
	return [dict create result {} events [list $ev]]
}
rio::dispatch::register buffer.replace rio::ops::buffer_replace
